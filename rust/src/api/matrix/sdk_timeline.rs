use std::{collections::HashMap, sync::Arc, time::Duration};

use futures_util::{stream, StreamExt};
use matrix_sdk::{
    event_cache::EventsOrigin,
    ruma::{
        api::client::receipt::create_receipt::v3::ReceiptType,
        events::{
            receipt::{ReceiptThread, ReceiptType as EventReceiptType},
            room::message::MessageType as RumaMessageType,
            AnySyncStateEvent, AnySyncTimelineEvent,
        },
    },
    Client, Room,
};
use matrix_sdk_ui::timeline::{
    EventTimelineItem, MembershipChange, MsgLikeKind, Profile, ReactionStatus, Timeline,
    TimelineBuilder, TimelineDetails, TimelineEventFocusThreadMode, TimelineFocus, TimelineItem,
    TimelineItemContent, TimelineReadReceiptTracking,
};
use once_cell::sync::Lazy;
use tokio::sync::Mutex;

use super::{
    image_info_dimensions, media_caption_parts, mentions_parts, sticker_info_dimensions,
    text_message_parts, uint_to_i32, unable_to_decrypt_message, ChatMessage, MessageReader,
    MessageType, PollAnswerInfo, PollAnswerResult, PollInfo, Reaction,
};

static TIMELINES: Lazy<Mutex<HashMap<String, Arc<Timeline>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn timeline_key(client: &Client, room: &Room) -> Result<String, String> {
    let user_id = client.user_id().ok_or("No active user")?;
    Ok(format!("{}\n{}", user_id, room.room_id()))
}

pub(super) async fn clear_all() {
    TIMELINES.lock().await.clear();
}

async fn get_or_create_timeline(client: &Client, room: &Room) -> Result<Arc<Timeline>, String> {
    let key = timeline_key(client, room)?;
    if let Some(timeline) = TIMELINES.lock().await.get(&key).cloned() {
        return Ok(timeline);
    }

    let timeline = Arc::new(
        TimelineBuilder::new(room)
            .track_read_marker_and_receipts(TimelineReadReceiptTracking::AllEvents)
            .build()
            .await
            .map_err(|error| format!("Failed to build room timeline: {error}"))?,
    );
    let mut timelines = TIMELINES.lock().await;
    Ok(timelines
        .entry(key)
        .or_insert_with(|| timeline.clone())
        .clone())
}

async fn snapshot(timeline: &Timeline) -> Vec<Arc<TimelineItem>> {
    let (items, updates) = timeline.subscribe().await;
    drop(updates);
    items.into_iter().collect()
}

fn remote_event_count(items: &[Arc<TimelineItem>]) -> usize {
    items
        .iter()
        .filter_map(|item| item.as_event())
        .filter(|event| event.event_id().is_some())
        .count()
}

fn loaded_expected_event_count<I, S>(
    loaded_ids: I,
    expected_ids: &[&matrix_sdk::ruma::EventId],
) -> usize
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    loaded_expected_event_ids(loaded_ids, expected_ids).len()
}

fn loaded_expected_event_ids<I, S>(
    loaded_ids: I,
    expected_ids: &[&matrix_sdk::ruma::EventId],
) -> std::collections::HashSet<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let loaded_ids: std::collections::HashSet<_> = loaded_ids
        .into_iter()
        .map(|event_id| event_id.as_ref().to_owned())
        .collect();
    expected_ids
        .iter()
        .filter(|expected_id| loaded_ids.contains(expected_id.as_str()))
        .map(|event_id| event_id.to_string())
        .collect()
}

fn pinned_events_ready(
    loaded_expected_events: usize,
    expected_events: usize,
    saw_network_update: bool,
) -> bool {
    loaded_expected_events == expected_events || (saw_network_update && loaded_expected_events > 0)
}

async fn ensure_initial_window(timeline: &Timeline, target: usize) -> Result<(), String> {
    for _ in 0..4 {
        let items = snapshot(timeline).await;
        let count = remote_event_count(&items);
        if count >= target {
            return Ok(());
        }
        let requested = target.saturating_sub(count).clamp(20, u16::MAX as usize) as u16;
        let hit_start = timeline
            .paginate_backwards(requested)
            .await
            .map_err(|error| format!("Failed to paginate room timeline: {error}"))?;
        let updated_count = remote_event_count(&snapshot(timeline).await);
        if hit_start || updated_count <= count {
            return Ok(());
        }
    }
    Ok(())
}

pub(super) async fn get_messages(client: &Client, room: &Room) -> Result<Vec<ChatMessage>, String> {
    const LIVE_WINDOW: usize = 100;

    let timeline = get_or_create_timeline(client, room).await?;
    ensure_initial_window(&timeline, LIVE_WINDOW).await?;

    match is_marked_unread(room).await {
        Ok(false) => {
            let _ = mark_as_read(&timeline, room).await;
        }
        Ok(true) => {}
        Err(error) => {
            super::app_log(
                "warn",
                "receipts",
                format!(
                    "Failed to load marked-unread flag for room {}: {error}",
                    room.room_id()
                ),
            );
        }
    }

    let mut messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    if messages.len() > LIVE_WINDOW {
        messages.drain(..messages.len() - LIVE_WINDOW);
    }
    Ok(messages)
}

/// Explicitly advance both Matrix read markers to the latest timeline event.
pub(super) async fn mark_room_as_read(client: &Client, room: &Room) -> Result<(), String> {
    let timeline = get_or_create_timeline(client, room).await?;
    ensure_initial_window(&timeline, 100).await?;
    mark_as_read(&timeline, room).await?;
    clear_marked_unread(room).await
}

/// Load every accessible pinned event, supplementing the SDK's bounded cache.
pub(super) async fn get_pinned_messages(room: &Room) -> Result<Vec<ChatMessage>, String> {
    let pinned_ids = room
        .load_pinned_events()
        .await
        .map_err(|error| format!("Failed to load pinned messages: {error}"))?
        .unwrap_or_default();
    if pinned_ids.is_empty() {
        return Ok(Vec::new());
    }

    let max_events_to_load = room
        .client()
        .event_cache()
        .config()
        .max_pinned_events_to_load;
    let expected_pinned_ids: Vec<_> = pinned_ids
        .iter()
        .rev()
        .take(max_events_to_load)
        .map(|event_id| event_id.as_ref())
        .collect();

    let (room_event_cache, _event_cache_drop_handles) = room
        .event_cache()
        .await
        .map_err(|error| format!("Failed to load pinned messages: {error}"))?;
    let (events, mut updates) = room_event_cache
        .subscribe_to_pinned_events()
        .await
        .map_err(|error| format!("Failed to load pinned messages: {error}"))?;
    let mut events: matrix_sdk_ui::eyeball_im::Vector<_> = events.into();
    let wait_result = tokio::time::timeout(Duration::from_secs(30), async {
        let mut saw_network_update = false;
        loop {
            let loaded_ids = loaded_expected_event_ids(
                events.iter().filter_map(|event| event.event_id()),
                &expected_pinned_ids,
            );
            if pinned_events_ready(
                loaded_ids.len(),
                expected_pinned_ids.len(),
                saw_network_update,
            ) {
                break;
            }

            let update = updates.recv().await.map_err(|error| error.to_string())?;
            let came_from_sync = matches!(update.origin, EventsOrigin::Sync);
            for diff in update.diffs {
                diff.apply(&mut events);
            }
            if came_from_sync {
                let updated_ids = loaded_expected_event_ids(
                    events.iter().filter_map(|event| event.event_id()),
                    &expected_pinned_ids,
                );
                saw_network_update |= updated_ids != loaded_ids;
            }
        }
        Ok::<(), String>(())
    })
    .await;

    let loaded_count = loaded_expected_event_count(
        events.iter().filter_map(|event| event.event_id()),
        &expected_pinned_ids,
    );
    let mut cache_error = if loaded_count == 0 {
        Some(match wait_result {
            Ok(Err(error)) => format!("Failed to load pinned messages: {error}"),
            Err(_) => "Timed out while loading pinned messages.".to_owned(),
            Ok(Ok(())) => "Failed to load any pinned messages.".to_owned(),
        })
    } else {
        None
    };

    let mut by_id = HashMap::new();
    if loaded_count > 0 {
        match TimelineBuilder::new(room)
            .with_focus(TimelineFocus::PinnedEvents)
            .build()
            .await
        {
            Ok(timeline) => {
                let items = snapshot(&timeline).await;
                by_id.extend(
                    convert_snapshot(room, &items)
                        .await
                        .into_iter()
                        .map(|message| (message.id.clone(), message)),
                );
            }
            Err(error) => {
                let error = format!("Failed to load pinned messages: {error}");
                super::app_log("warn", "pinned", error.clone());
                cache_error = Some(error);
            }
        }
    }

    let missing_ids = missing_pinned_event_ids(&pinned_ids, &by_id);
    let fetched = stream::iter(missing_ids)
        .map(|event_id| {
            let room = room.clone();
            async move {
                let result = load_focused_message(&room, event_id.clone()).await;
                (event_id, result)
            }
        })
        .buffer_unordered(8)
        .collect::<Vec<_>>()
        .await;
    let mut focused_error = None;
    for (event_id, result) in fetched {
        match result {
            Ok(Some(message)) => {
                by_id.insert(event_id.to_string(), message);
            }
            Ok(None) => {}
            Err(error) => {
                focused_error.get_or_insert_with(|| error.clone());
                super::app_log(
                    "warn",
                    "pinned",
                    format!("Failed to load pinned event {event_id}: {error}"),
                );
            }
        }
    }

    if by_id.is_empty() {
        return Err(focused_error
            .map(|error| format!("Failed to load pinned messages: {error}"))
            .or(cache_error)
            .unwrap_or_else(|| "Failed to load any pinned messages.".to_owned()));
    }

    Ok(ordered_pinned_messages(&pinned_ids, &by_id))
}

async fn load_focused_message(
    room: &Room,
    event_id: matrix_sdk::ruma::OwnedEventId,
) -> Result<Option<ChatMessage>, String> {
    let timeline = TimelineBuilder::new(room)
        .with_focus(TimelineFocus::Event {
            target: event_id.clone(),
            num_context_events: 0,
            thread_mode: TimelineEventFocusThreadMode::Automatic {
                hide_threaded_events: false,
            },
        })
        .build()
        .await
        .map_err(|error| format!("Failed to load event: {error}"))?;
    Ok(convert_snapshot(room, &snapshot(&timeline).await)
        .await
        .into_iter()
        .find(|message| message.id == event_id.as_str()))
}

fn ordered_pinned_messages(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<ChatMessage> {
    pinned_ids
        .iter()
        .filter_map(|event_id| by_id.get(event_id.as_str()).cloned())
        .collect()
}

fn missing_pinned_event_ids(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<matrix_sdk::ruma::OwnedEventId> {
    pinned_ids
        .iter()
        .filter(|event_id| !by_id.contains_key(event_id.as_str()))
        .cloned()
        .collect()
}

async fn mark_as_read(timeline: &Timeline, room: &Room) -> Result<(), String> {
    // The Timeline guards against moving either marker backwards.
    let read_error = match timeline.mark_as_read(ReceiptType::Read).await {
        Ok(sent) => {
            if sent {
                super::app_log(
                    "info",
                    "receipts",
                    format!("Sent explicit read receipt for room {}", room.room_id()),
                );
            }
            None
        }
        Err(error) => {
            let error = error.to_string();
            super::app_log(
                "warn",
                "receipts",
                format!(
                    "Failed to send explicit read receipt for room {}: {error}",
                    room.room_id()
                ),
            );
            Some(error)
        }
    };
    let fully_read_error = match timeline.mark_as_read(ReceiptType::FullyRead).await {
        Ok(_) => None,
        Err(error) => {
            let error = error.to_string();
            super::app_log(
                "warn",
                "receipts",
                format!(
                    "Failed to update fully-read marker for room {}: {error}",
                    room.room_id()
                ),
            );
            Some(error)
        }
    };
    match (read_error, fully_read_error) {
        (None, None) => Ok(()),
        (Some(read_error), None) => Err(format!(
            "Failed to mark room as read: read receipt: {read_error}"
        )),
        (None, Some(fully_read_error)) => Err(format!(
            "Failed to mark room as read: fully-read marker: {fully_read_error}"
        )),
        (Some(read_error), Some(fully_read_error)) => Err(format!(
            "Failed to mark room as read: read receipt: {read_error}; fully-read marker: {fully_read_error}"
        )),
    }
}

/// Drop the explicit `m.marked_unread` flag for an explicit read action.
async fn clear_marked_unread(room: &Room) -> Result<(), String> {
    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    room.set_account_data(MarkedUnreadEventContent::new(false))
        .await
        .map(|_| ())
        .map_err(|error| format!("Failed to clear marked-unread flag: {error}"))
}

async fn is_marked_unread(room: &Room) -> Result<bool, String> {
    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    Ok(room
        .account_data_static::<MarkedUnreadEventContent>()
        .await
        .map_err(|error| format!("Failed to load marked-unread flag: {error}"))?
        .map(|raw| raw.deserialize())
        .transpose()
        .map_err(|error| format!("Failed to decode marked-unread flag: {error}"))?
        .is_some_and(|event| event.content.unread))
}

pub(super) async fn get_messages_before(
    client: &Client,
    room: &Room,
    from_event_id: &str,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let timeline = get_or_create_timeline(client, room).await?;
    let limit = limit.min(u16::MAX as u32) as usize;
    if limit == 0 {
        return Ok(Vec::new());
    }

    let current = convert_snapshot(room, &snapshot(&timeline).await).await;
    let available = messages_before(&current, from_event_id).len();
    if available < limit {
        timeline
            .paginate_backwards((limit - available).max(20) as u16)
            .await
            .map_err(|error| format!("Failed to paginate room timeline: {error}"))?;
    }

    let messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    let before = messages_before(&messages, from_event_id);
    Ok(before[before.len().saturating_sub(limit)..].to_vec())
}

fn messages_before<'a>(messages: &'a [ChatMessage], event_id: &str) -> &'a [ChatMessage] {
    messages
        .iter()
        .position(|message| message.id == event_id)
        .map(|position| &messages[..position])
        .unwrap_or_default()
}

async fn convert_snapshot(room: &Room, items: &[Arc<TimelineItem>]) -> Vec<ChatMessage> {
    let my_user_id = room.client().user_id().map(ToString::to_string);
    let event_items: Vec<&EventTimelineItem> =
        items.iter().filter_map(|item| item.as_event()).collect();
    let event_positions: HashMap<String, usize> = event_items
        .iter()
        .enumerate()
        .filter_map(|(position, event)| {
            event
                .event_id()
                .map(|event_id| (event_id.to_string(), position))
        })
        .collect();
    let mut receipt_positions = HashMap::new();
    for (position, event) in event_items.iter().enumerate() {
        for user_id in event.read_receipts().keys() {
            if my_user_id.as_deref() != Some(user_id.as_str()) {
                record_latest_receipt_position(
                    &mut receipt_positions,
                    user_id.to_string(),
                    position,
                );
            }
        }
    }
    let members = room
        .members(matrix_sdk::RoomMemberships::JOIN)
        .await
        .unwrap_or_default();

    // The timeline includes implicit receipts (for example, sending an event
    // means that member read everything before it), which the state store does
    // not persist. Keep those positions, then merge in explicit receipts from
    // the store. The store is written synchronously while the sync response is
    // processed, so it also covers the race where the timeline's background
    // receipt task has not drained before this snapshot.
    //
    // A store receipt only supplies a position when its target is in this
    // snapshot. An unknown target can be either older or newer than the
    // window, so inventing a position would show a false receipt. Check both
    // unthreaded and main receipts: clients can write either one.
    let member_receipts = futures_util::future::join_all(
        members
            .iter()
            .filter_map(|member| {
                let user_id = member.user_id();
                if my_user_id.as_deref() == Some(user_id.as_str()) {
                    return None;
                }
                let user_id = user_id.to_owned();
                let room = room.clone();
                let event_positions = &event_positions;
                Some(async move {
                    let (unthreaded, main) = tokio::join!(
                        room.load_user_receipt(
                            EventReceiptType::Read,
                            ReceiptThread::Unthreaded,
                            &user_id,
                        ),
                        room.load_user_receipt(
                            EventReceiptType::Read,
                            ReceiptThread::Main,
                            &user_id,
                        ),
                    );
                    let unthreaded = unthreaded.ok().flatten();
                    let main = main.ok().flatten();
                    let position = newest_receipt_position(
                        [unthreaded.as_ref(), main.as_ref()]
                            .into_iter()
                            .flatten()
                            .map(|receipt| receipt.0.as_ref()),
                        event_positions,
                    )?;
                    Some((user_id.to_string(), position))
                })
            })
            .collect::<Vec<_>>(),
    )
    .await;
    for (user_id, position) in member_receipts.into_iter().flatten() {
        record_latest_receipt_position(&mut receipt_positions, user_id, position);
    }

    let mut profiles: HashMap<String, (String, Option<String>)> = members
        .iter()
        .map(|member| {
            (
                member.user_id().to_string(),
                (
                    member.name().to_string(),
                    member.avatar_url().map(ToString::to_string),
                ),
            )
        })
        .collect();
    for event in &event_items {
        if let TimelineDetails::Ready(Profile {
            display_name,
            avatar_url,
            ..
        }) = event.sender_profile()
        {
            profiles
                .entry(event.sender().to_string())
                .or_insert_with(|| {
                    (
                        display_name
                            .clone()
                            .unwrap_or_else(|| event.sender().localpart().to_owned()),
                        avatar_url.as_ref().map(ToString::to_string),
                    )
                });
        }
    }
    let base_total_members = room.active_members_count().min(i32::MAX as u64) as i32;

    let mut messages: Vec<ChatMessage> = event_items
        .iter()
        .filter_map(|event| timeline_item_to_message(event, my_user_id.as_deref()))
        .collect();
    for message in &mut messages {
        message.total_members = base_total_members;
        if !message.is_me {
            continue;
        }
        let Some(message_position) = event_positions.get(&message.id) else {
            continue;
        };
        let readers_at_message = reader_ids_for_position(&receipt_positions, *message_position);
        let readers: Vec<MessageReader> = readers_at_message
            .into_iter()
            .map(|user_id| {
                let (display_name, avatar_url) =
                    profiles.get(&user_id).cloned().unwrap_or_else(|| {
                        (
                            user_id
                                .split(':')
                                .next()
                                .unwrap_or(&user_id)
                                .trim_start_matches('@')
                                .to_owned(),
                            None,
                        )
                    });
                MessageReader {
                    user_id,
                    display_name,
                    avatar_url,
                }
            })
            .collect();
        message.total_members = message.total_members.max(readers.len() as i32 + 1);
        message.readers = readers;
    }
    messages
}

fn record_latest_receipt_position(
    receipt_positions: &mut HashMap<String, usize>,
    user_id: String,
    position: usize,
) {
    receipt_positions
        .entry(user_id)
        .and_modify(|current| *current = (*current).max(position))
        .or_insert(position);
}

fn newest_receipt_position<'a>(
    receipt_event_ids: impl IntoIterator<Item = &'a matrix_sdk::ruma::EventId>,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    receipt_event_ids
        .into_iter()
        .filter_map(|event_id| resolve_receipt_position(event_id, event_positions))
        .max()
}

fn resolve_receipt_position(
    receipt_event_id: &matrix_sdk::ruma::EventId,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    event_positions.get(receipt_event_id.as_str()).copied()
}

fn reader_ids_for_position(
    receipt_positions: &HashMap<String, usize>,
    message_position: usize,
) -> Vec<String> {
    let mut readers: Vec<String> = receipt_positions
        .iter()
        .filter(|(_, receipt_position)| **receipt_position >= message_position)
        .map(|(user_id, _)| user_id.clone())
        .collect();
    readers.sort();
    readers
}

fn timeline_item_to_message(
    item: &EventTimelineItem,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let event_id = item.event_id()?.to_string();
    let sender_id = item.sender().to_string();
    let is_me = my_user_id == Some(sender_id.as_str());
    let sender_name = if is_me {
        "我".to_owned()
    } else if let TimelineDetails::Ready(profile) = item.sender_profile() {
        profile
            .display_name
            .clone()
            .unwrap_or_else(|| item.sender().localpart().to_owned())
    } else {
        item.sender().localpart().to_owned()
    };
    let timestamp = u64::from(item.timestamp().0).to_string();

    let mut message = match item.content() {
        TimelineItemContent::MsgLike(content) => {
            let in_reply_to = content
                .in_reply_to
                .as_ref()
                .map(|reply| reply.event_id.to_string());
            match &content.kind {
                MsgLikeKind::Message(message) => message_to_chat_message(
                    &event_id,
                    &sender_id,
                    &sender_name,
                    &timestamp,
                    is_me,
                    in_reply_to,
                    message,
                    item,
                )?,
                MsgLikeKind::Sticker(sticker) => {
                    let content = sticker.content();
                    let source = &content.source;
                    let image_url = match source {
                        matrix_sdk::ruma::events::sticker::StickerMediaSource::Plain(mxc) => {
                            Some(mxc.to_string())
                        }
                        _ => None,
                    };
                    let (image_width, image_height) = sticker_info_dimensions(&content.info);
                    ChatMessage {
                        id: event_id,
                        sender_id,
                        sender_name,
                        content: content.body.clone(),
                        formatted_body: None,
                        caption: None,
                        caption_formatted_body: None,
                        mentioned_user_ids: Vec::new(),
                        mentions_room: false,
                        timestamp,
                        is_me,
                        msg_type: MessageType::Sticker,
                        image_url,
                        media_source_json: serde_json::to_string(source).ok(),
                        image_width,
                        image_height,
                        filename: None,
                        file_size: None,
                        geo_uri: None,
                        poll: None,
                        in_reply_to,
                        is_edited: false,
                        edit_history: Vec::new(),
                        reactions: Vec::new(),
                        readers: Vec::new(),
                        total_members: 0,
                    }
                }
                MsgLikeKind::UnableToDecrypt(_) => {
                    unable_to_decrypt_message(event_id, sender_id, sender_name, timestamp, is_me)
                }
                MsgLikeKind::Poll(state) => poll_message(
                    event_id,
                    sender_id,
                    sender_name,
                    timestamp,
                    is_me,
                    in_reply_to,
                    state,
                    my_user_id,
                )?,
                _ => return None,
            }
        }
        TimelineItemContent::MembershipChange(change) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: membership_label(change)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        TimelineItemContent::OtherState(_) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: state_event_label(item)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        _ => return None,
    };
    message.reactions = timeline_reactions(item, my_user_id);
    Some(message)
}

#[allow(clippy::too_many_arguments)]
fn message_to_chat_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    in_reply_to: Option<String>,
    message: &matrix_sdk_ui::timeline::Message,
    item: &EventTimelineItem,
) -> Option<ChatMessage> {
    let mentions = message.mentions();
    let mut result = match message.msgtype() {
        RumaMessageType::Text(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Notice(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Emote(text) => {
            let (body, _, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                format!("* {sender_name} {body}"),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Image(image) => {
            let image_url = match &image.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = image_info_dimensions(image.info.as_ref());
            let (caption, caption_formatted_body) =
                media_caption_parts(image.formatted_caption(), image.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                image.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Image,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&image.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result
        }
        RumaMessageType::Video(video) => {
            let image_url = match &video.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = video
                .info
                .as_ref()
                .map(|info| (uint_to_i32(info.width), uint_to_i32(info.height)))
                .unwrap_or((None, None));
            let (caption, caption_formatted_body) =
                media_caption_parts(video.formatted_caption(), video.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                video.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Video,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&video.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result
        }
        RumaMessageType::File(file) => {
            let filename = file.filename().to_string();
            let image_url = match &file.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(file.formatted_caption(), file.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = file.info.as_deref().and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&file.source).ok();
            result
        }
        RumaMessageType::Audio(audio) => {
            let filename = audio.filename().to_string();
            let image_url = match &audio.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(audio.formatted_caption(), audio.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = audio
                .info
                .as_deref()
                .and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&audio.source).ok();
            result
        }
        RumaMessageType::Location(location) => {
            let geo_uri = location.geo_uri.clone();
            let body = location.body.clone();
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                if body.trim().is_empty() {
                    geo_uri.clone()
                } else {
                    body
                },
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Location,
                in_reply_to,
            );
            result.geo_uri = Some(geo_uri);
            result
        }
        _ => return None,
    };
    result.is_edited = message.is_edited();
    if result.is_edited {
        if let Some(original) = original_message_body(item) {
            result.edit_history = vec![original, result.content.clone()];
        }
    }
    Some(result)
}

#[allow(clippy::too_many_arguments)]
fn base_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    content: String,
    formatted_body: Option<String>,
    mentioned_user_ids: Vec<String>,
    mentions_room: bool,
    msg_type: MessageType,
    in_reply_to: Option<String>,
) -> ChatMessage {
    ChatMessage {
        id: event_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: sender_name.to_owned(),
        content,
        formatted_body,
        caption: None,
        caption_formatted_body: None,
        mentioned_user_ids,
        mentions_room,
        timestamp: timestamp.to_owned(),
        is_me,
        msg_type,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        geo_uri: None,
        poll: None,
        in_reply_to,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

/// Build a [ChatMessage] from a poll timeline item. Polls use the unstable
/// `org.matrix.msc3381.*` event type, surfaced as [MsgLikeKind::Poll].
#[allow(clippy::too_many_arguments)]
fn poll_message(
    event_id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    is_me: bool,
    in_reply_to: Option<String>,
    state: &matrix_sdk_ui::timeline::PollState,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let result = state.results();

    let answers = result
        .answers
        .into_iter()
        .map(|answer| PollAnswerInfo {
            id: answer.id,
            text: answer.text,
        })
        .collect::<Vec<_>>();
    if answers.is_empty() {
        return None;
    }

    let disclosed = result.kind == matrix_sdk::ruma::events::poll::start::PollKind::Disclosed;
    let ended = result.end_time.is_some();
    // Aggregate per-answer tallies and detect the current user's selections.
    let mut my_answer_ids = Vec::new();
    let mut tally: HashMap<&str, i32> = HashMap::new();
    let mut voters: HashMap<&str, ()> = HashMap::new();
    for (answer_id, voters_for_answer) in &result.votes {
        let count = i32::try_from(voters_for_answer.len()).unwrap_or(i32::MAX);
        tally.insert(answer_id.as_str(), count);
        for voter in voters_for_answer {
            voters.insert(voter.as_str(), ());
            if Some(voter.as_str()) == my_user_id {
                my_answer_ids.push(answer_id.clone());
            }
        }
    }

    let results = answers
        .iter()
        .map(|answer| PollAnswerResult {
            answer_id: answer.id.clone(),
            count: *tally.get(answer.id.as_str()).unwrap_or(&0),
            is_mine: my_answer_ids.iter().any(|id| id == &answer.id),
        })
        .collect::<Vec<_>>();

    let mut message = base_message(
        &event_id,
        &sender_id,
        &sender_name,
        &timestamp,
        is_me,
        result.question.clone(),
        None,
        Vec::new(),
        false,
        MessageType::Poll,
        in_reply_to,
    );
    message.poll = Some(PollInfo {
        question: result.question,
        answers,
        disclosed,
        max_selections: i32::try_from(result.max_selections).unwrap_or(i32::MAX),
        my_answer_ids,
        results,
        total_voters: i32::try_from(voters.len()).unwrap_or(i32::MAX),
        ended,
    });
    Some(message)
}

fn original_message_body(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::MessageLike(
        matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
    ) = event
    else {
        return None;
    };
    Some(message.as_original()?.content.msgtype.body().to_owned())
}

fn timeline_reactions(item: &EventTimelineItem, my_user_id: Option<&str>) -> Vec<Reaction> {
    item.content()
        .reactions()
        .into_iter()
        .flat_map(|reactions| reactions.iter())
        .map(|(key, by_sender)| Reaction {
            key: key.clone(),
            senders: by_sender.keys().map(ToString::to_string).collect(),
            my_event_id: my_user_id
                .and_then(|user_id| by_sender.get(user_id))
                .and_then(|reaction| match &reaction.status {
                    ReactionStatus::RemoteToRemote(event_id) => Some(event_id.to_string()),
                    _ => None,
                }),
        })
        .collect()
}

fn membership_label(change: &matrix_sdk_ui::timeline::RoomMembershipChange) -> Option<String> {
    let name = change
        .display_name()
        .unwrap_or_else(|| change.user_id().localpart().to_owned());
    match change.change()? {
        MembershipChange::Joined | MembershipChange::InvitationAccepted => {
            Some(format!("{name} 加入了房间"))
        }
        MembershipChange::Left
        | MembershipChange::Kicked
        | MembershipChange::InvitationRejected
        | MembershipChange::InvitationRevoked => Some(format!("{name} 离开了房间")),
        MembershipChange::Banned | MembershipChange::KickedAndBanned => {
            Some(format!("{name} 被封禁"))
        }
        MembershipChange::Invited => Some(format!("{name} 收到了加入房间的邀请")),
        MembershipChange::Knocked => Some(format!("{name} 请求加入房间")),
        _ => None,
    }
}

fn state_event_label(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::State(state) = event else {
        return None;
    };
    match state {
        AnySyncStateEvent::RoomCreate(_) => Some("房间已创建".to_owned()),
        AnySyncStateEvent::RoomName(name) => name
            .as_original()
            .map(|event| format!("房间名称更改为: {}", event.content.name)),
        AnySyncStateEvent::RoomTopic(topic) => topic
            .as_original()
            .map(|event| format!("主题更改为: {}", event.content.topic)),
        AnySyncStateEvent::RoomAvatar(_) => Some("房间头像已更改".to_owned()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        loaded_expected_event_count, loaded_expected_event_ids, messages_before,
        missing_pinned_event_ids, newest_receipt_position, ordered_pinned_messages,
        pinned_events_ready, reader_ids_for_position, record_latest_receipt_position,
        resolve_receipt_position,
    };
    use crate::api::matrix::uint_to_i32;
    use crate::api::matrix::{ChatMessage, MessageType};
    use std::collections::HashMap;

    fn message(id: &str) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            sender_id: "@alice:example.org".to_owned(),
            sender_name: "Alice".to_owned(),
            content: id.to_owned(),
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp: "0".to_owned(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 2,
        }
    }

    #[test]
    fn slices_messages_before_the_requested_boundary() {
        let messages = vec![message("$a"), message("$b"), message("$c")];
        assert_eq!(
            messages_before(&messages, "$c")
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["$a", "$b"]
        );
    }

    #[test]
    fn counts_only_expected_loaded_events() {
        use matrix_sdk::ruma::EventId;

        let first = EventId::parse("$first:example.org").unwrap();
        let missing = EventId::parse("$missing:example.org").unwrap();
        let expected = [first.as_ref(), missing.as_ref()];

        assert_eq!(
            loaded_expected_event_count([first.as_str(), "$other"].into_iter(), &expected),
            1
        );
        assert_eq!(
            loaded_expected_event_count(std::iter::empty::<&str>(), &expected),
            0
        );
    }

    #[test]
    fn complete_cache_is_ready_without_a_network_update() {
        assert!(pinned_events_ready(2, 2, false));
    }

    #[test]
    fn partial_cache_waits_for_a_network_update() {
        assert!(!pinned_events_ready(1, 2, false));
        assert!(pinned_events_ready(1, 2, true));
    }

    #[test]
    fn unrelated_sync_update_does_not_release_partial_cache() {
        use matrix_sdk::ruma::EventId;

        let first = EventId::parse("$first:example.org").unwrap();
        let missing = EventId::parse("$missing:example.org").unwrap();
        let expected = [first.as_ref(), missing.as_ref()];
        let cached = loaded_expected_event_ids([first.as_str()], &expected);
        let after_relation =
            loaded_expected_event_ids([first.as_str(), "$reaction:example.org"], &expected);

        assert_eq!(cached, after_relation);
        assert!(!pinned_events_ready(
            after_relation.len(),
            expected.len(),
            after_relation != cached,
        ));
    }

    #[test]
    fn empty_network_result_is_not_ready() {
        assert!(!pinned_events_ready(0, 2, true));
    }

    #[test]
    fn supplements_a_bounded_pinned_cache_and_preserves_state_order() {
        use matrix_sdk::ruma::EventId;

        let pinned_ids = (0..130)
            .map(|index| EventId::parse(format!("$pin-{index}:example.org")).unwrap())
            .collect::<Vec<_>>();
        let bounded_cache = pinned_ids
            .iter()
            .skip(2)
            .map(|event_id| (event_id.to_string(), message(event_id.as_str())))
            .collect::<HashMap<_, _>>();

        assert_eq!(
            missing_pinned_event_ids(&pinned_ids, &bounded_cache)
                .iter()
                .map(|event_id| event_id.as_str())
                .collect::<Vec<_>>(),
            ["$pin-0:example.org", "$pin-1:example.org"]
        );

        let all_messages = pinned_ids
            .iter()
            .map(|event_id| (event_id.to_string(), message(event_id.as_str())))
            .collect::<HashMap<_, _>>();
        let ordered = ordered_pinned_messages(&pinned_ids, &all_messages);
        assert_eq!(ordered.len(), 130);
        assert_eq!(ordered.first().unwrap().id, "$pin-0:example.org");
        assert_eq!(ordered.last().unwrap().id, "$pin-129:example.org");
    }

    #[test]
    fn receipt_positions_apply_cumulatively_without_timestamps() {
        let receipts = HashMap::from([
            ("@bob:example.org".to_owned(), 4),
            ("@carol:example.org".to_owned(), 2),
        ]);

        assert_eq!(reader_ids_for_position(&receipts, 3), ["@bob:example.org"]);
        assert_eq!(
            reader_ids_for_position(&receipts, 2),
            ["@bob:example.org", "@carol:example.org"]
        );
    }

    #[test]
    fn implicit_receipt_is_not_replaced_by_older_explicit_receipt() {
        let mut positions = HashMap::new();

        record_latest_receipt_position(&mut positions, "@bob:example.org".to_owned(), 4);
        record_latest_receipt_position(&mut positions, "@bob:example.org".to_owned(), 1);

        assert_eq!(positions["@bob:example.org"], 4);
        assert_eq!(reader_ids_for_position(&positions, 3), ["@bob:example.org"]);
    }

    #[test]
    fn store_receipts_use_the_newest_known_main_timeline_position() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([
            ("$a:example.org".to_owned(), 0),
            ("$unthreaded:example.org".to_owned(), 1),
            ("$main:example.org".to_owned(), 4),
        ]);
        let unthreaded = EventId::parse("$unthreaded:example.org").unwrap();
        let main = EventId::parse("$main:example.org").unwrap();

        assert_eq!(
            newest_receipt_position([unthreaded.as_ref(), main.as_ref()], &positions),
            Some(4)
        );
    }

    #[test]
    fn unknown_receipt_target_does_not_mark_the_oldest_message_as_read() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([("$a:example.org".to_owned(), 0)]);

        assert_eq!(
            resolve_receipt_position(
                EventId::parse("$outside:example.org").unwrap().as_ref(),
                &positions
            ),
            None
        );
    }

    #[test]
    fn unknown_unthreaded_receipt_does_not_hide_a_known_main_receipt() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([("$main:example.org".to_owned(), 4)]);
        let unthreaded = EventId::parse("$outside:example.org").unwrap();
        let main = EventId::parse("$main:example.org").unwrap();

        assert_eq!(
            newest_receipt_position([unthreaded.as_ref(), main.as_ref()], &positions),
            Some(4)
        );
    }

    #[test]
    fn file_sizes_cross_the_bridge_as_saturating_i32() {
        assert_eq!(
            uint_to_i32(matrix_sdk::ruma::UInt::new(64 * 1024 * 1024)),
            Some(64 * 1024 * 1024)
        );
        assert_eq!(
            uint_to_i32(matrix_sdk::ruma::UInt::new(i32::MAX as u64 + 1)),
            Some(i32::MAX)
        );
        assert_eq!(uint_to_i32(None), None);
    }
}
