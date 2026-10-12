use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use matrix_sdk::{
    deserialized_responses::SyncOrStrippedState,
    ruma::events::{
        image_pack::rooms::ImagePackRoomsEventContent,
        macros::EventContent,
        room::image_pack::{ImagePackImage, ImagePackMeta, PackUsage, RoomImagePackEventContent},
        SyncStateEvent,
    },
    Client, Room,
};
use serde::{Deserialize, Serialize};

use super::{api_err, room_display_name, uint_to_i32, Sticker, StickerPack};

// Ruma 0.35 removed the MSC2545 types. Keep the room format readable until
// existing rooms migrate their state to m.room.image_pack.
#[derive(Clone, Debug, Deserialize, Serialize, EventContent)]
#[ruma_event(type = "im.ponies.room_emotes", kind = State, state_key_type = String)]
struct LegacyRoomImagePackEventContent {
    images: BTreeMap<String, LegacyPackImage>,
    pack: Option<ImagePackMeta>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct LegacyPackImage {
    #[serde(flatten)]
    image: ImagePackImage,
    #[serde(default)]
    usage: BTreeSet<PackUsage>,
}

fn usage_allows_sticker(usage: &BTreeSet<PackUsage>) -> bool {
    usage.is_empty() || usage.contains(&PackUsage::Sticker)
}

fn pack_image_to_sticker(shortcode: String, image: ImagePackImage) -> Sticker {
    let body = image
        .body
        .as_deref()
        .map(str::trim)
        .filter(|body| !body.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| shortcode.clone());
    let image_url = image.url.to_string();
    let thumbnail_url = None;
    let mime_type = image.info.as_ref().and_then(|info| info.mimetype.clone());
    let width = image.info.as_ref().and_then(|info| uint_to_i32(info.width));
    let height = image
        .info
        .as_ref()
        .and_then(|info| uint_to_i32(info.height));

    Sticker {
        id: shortcode.clone(),
        shortcode,
        body,
        image_url,
        thumbnail_url,
        mime_type,
        width,
        height,
    }
}

fn room_image_pack_to_sticker_pack(
    room: &Room,
    state_key: String,
    pack: ImagePackMeta,
    mut stickers: Vec<Sticker>,
) -> Option<StickerPack> {
    if stickers.is_empty() {
        return None;
    }
    stickers.sort_by_key(|a| a.body.to_lowercase());

    let title = pack
        .display_name
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            let trimmed = state_key.trim();
            if trimmed.is_empty() {
                room_display_name(room)
            } else {
                trimmed.to_string()
            }
        });
    let avatar_url = pack
        .avatar_url
        .as_ref()
        .map(ToString::to_string)
        .or_else(|| room.avatar_url().map(|url| url.to_string()));
    let normalized_state_key = if state_key.trim().is_empty() {
        "default".to_string()
    } else {
        state_key
    };

    Some(StickerPack {
        id: format!("room:{}:{normalized_state_key}", room.room_id()),
        title,
        avatar_url,
        source: "room".to_string(),
        stickers,
    })
}

async fn load_room_sticker_packs(
    room: &Room,
    enabled_state_keys: Option<&HashSet<String>>,
) -> Result<Vec<StickerPack>, String> {
    let load_error = |error| {
        api_err(
            "rooms",
            format!(
                "Failed to load sticker packs for room {}: {error}",
                room.room_id()
            ),
        )
    };
    let stable_events = room
        .get_state_events_static::<RoomImagePackEventContent>()
        .await
        .map_err(load_error)?;
    let legacy_events = room
        .get_state_events_static::<LegacyRoomImagePackEventContent>()
        .await
        .map_err(load_error)?;

    let mut packs = Vec::new();
    let mut seen_state_keys = HashSet::new();
    // Prefer the stable event when a room publishes both formats for one key.
    for raw in stable_events {
        let Ok(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) = raw.deserialize()
        else {
            continue;
        };
        if enabled_state_keys.is_some_and(|keys| !keys.contains(&event.state_key)) {
            continue;
        }
        let content = event.content;
        let stickers = if usage_allows_sticker(&content.pack.usage) {
            content
                .images
                .into_iter()
                .map(|(key, image)| pack_image_to_sticker(key, image))
                .collect()
        } else {
            Vec::new()
        };
        if let Some(pack) =
            room_image_pack_to_sticker_pack(room, event.state_key.clone(), content.pack, stickers)
        {
            seen_state_keys.insert(event.state_key);
            packs.push(pack);
        }
    }
    for raw in legacy_events {
        let Ok(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) = raw.deserialize()
        else {
            continue;
        };
        if seen_state_keys.contains(&event.state_key)
            || enabled_state_keys.is_some_and(|keys| !keys.contains(&event.state_key))
        {
            continue;
        }
        let content = event.content;
        let pack = content.pack.unwrap_or_default();
        let pack_allows_sticker = usage_allows_sticker(&pack.usage);
        let stickers = content
            .images
            .into_iter()
            .filter_map(|(key, image)| {
                let allows_sticker = if image.usage.is_empty() {
                    pack_allows_sticker
                } else {
                    usage_allows_sticker(&image.usage)
                };
                allows_sticker.then(|| pack_image_to_sticker(key, image.image))
            })
            .collect();
        if let Some(pack) = room_image_pack_to_sticker_pack(room, event.state_key, pack, stickers) {
            packs.push(pack);
        }
    }
    Ok(packs)
}

pub(super) async fn get_sticker_packs(
    client: &Client,
    room: &Room,
) -> Result<Vec<StickerPack>, String> {
    let mut imported_room_packs: HashMap<String, HashSet<String>> = HashMap::new();
    // Both account-data formats have the same content shape. Read them from
    // the local store, just like the room state; no server-side migration needed.
    for event_type in ["m.image_pack.rooms", "im.ponies.emote_rooms"] {
        let content = client
            .account()
            .account_data_raw(event_type.into())
            .await
            .map_err(|e| {
                api_err(
                    "media",
                    format!("Failed to load image-pack room mapping: {e}"),
                )
            })?
            .and_then(|raw| {
                raw.deserialize_as_unchecked::<ImagePackRoomsEventContent>()
                    .ok()
            });
        if let Some(content) = content {
            for (room_id, packs) in content.rooms {
                imported_room_packs
                    .entry(room_id.to_string())
                    .or_default()
                    .extend(packs.into_keys());
            }
        }
    }

    let mut packs = Vec::new();
    let mut seen_pack_ids = HashSet::new();
    for pack in load_room_sticker_packs(room, None).await? {
        if seen_pack_ids.insert(pack.id.clone()) {
            packs.push(pack);
        }
    }
    for (source_room_id, enabled_state_keys) in imported_room_packs {
        let Ok(parsed_source_room_id) = matrix_sdk::ruma::RoomId::parse(&source_room_id) else {
            continue;
        };
        let Some(source_room) = client.get_room(&parsed_source_room_id) else {
            continue;
        };
        for pack in load_room_sticker_packs(&source_room, Some(&enabled_state_keys)).await? {
            if seen_pack_ids.insert(pack.id.clone()) {
                packs.push(pack);
            }
        }
    }
    packs.sort_by_key(|pack| pack.title.to_lowercase());
    Ok(packs)
}

#[cfg(test)]
mod tests {
    use matrix_sdk::{
        ruma::{room_id, serde::Raw},
        test_utils::mocks::MatrixMockServer,
    };
    use matrix_sdk_test::JoinedRoomBuilder;
    use serde_json::{json, Value};

    fn pack_event(
        event_type: &str,
        state_key: &str,
        content: Value,
    ) -> Raw<matrix_sdk::ruma::events::AnySyncStateEvent> {
        Raw::from_json_string(
            json!({
                "type": event_type, "state_key": state_key, "content": content,
                "event_id": format!("${event_type}-{state_key}:localhost"),
                "sender": "@alice:localhost", "origin_server_ts": 1,
            })
            .to_string(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn reads_both_room_formats_and_preserves_legacy_image_usage() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let room_id = room_id!("!stickers:localhost");
        server.sync_room(&client, JoinedRoomBuilder::new(room_id)
            .add_state_event(pack_event("im.ponies.room_emotes", "legacy", json!({
                "pack": {"usage": ["emoticon"]},
                "images": {
                    "inherit": {"url": "mxc://localhost/inherit"},
                    "override": {"url": "mxc://localhost/override", "usage": ["sticker"]},
                }
            })))
            .add_state_event(pack_event("im.ponies.room_emotes", "shared", json!({
                "pack": null, "images": {"old": {"url": "mxc://localhost/old"}}
            })))
            .add_state_event(pack_event("m.room.image_pack", "shared", json!({
                "images": {"new": {"url": "mxc://localhost/new"}}
            })))
        ).await;
        let room = client.get_room(room_id).unwrap();
        let packs = super::get_sticker_packs(&client, &room).await.unwrap();
        assert_eq!(packs.len(), 2);
        let legacy = packs.iter().find(|pack| pack.title == "legacy").unwrap();
        assert_eq!(legacy.stickers.len(), 1);
        assert_eq!(legacy.stickers[0].shortcode, "override");
        let shared = packs.iter().find(|pack| pack.title == "shared").unwrap();
        assert_eq!(shared.stickers[0].shortcode, "new");
    }

    #[tokio::test]
    async fn merges_old_and_new_imports_without_showing_disabled_packs() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let target_id = room_id!("!target:localhost");
        let source_id = room_id!("!source:localhost");
        server
            .sync_room(&client, JoinedRoomBuilder::new(target_id))
            .await;
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(source_id)
                    .add_state_event(pack_event(
                        "im.ponies.room_emotes",
                        "old",
                        json!({
                            "images": {"old": {"url": "mxc://localhost/old"}}
                        }),
                    ))
                    .add_state_event(pack_event(
                        "m.room.image_pack",
                        "new",
                        json!({
                            "images": {"new": {"url": "mxc://localhost/new"}}
                        }),
                    ))
                    .add_state_event(pack_event(
                        "im.ponies.room_emotes",
                        "disabled",
                        json!({
                            "images": {"disabled": {"url": "mxc://localhost/disabled"}}
                        }),
                    )),
            )
            .await;
        server
            .mock_sync()
            .ok_and_run(&client, |sync| {
                for (event_type, state_key) in [
                    ("im.ponies.emote_rooms", "old"),
                    ("m.image_pack.rooms", "new"),
                ] {
                    sync.add_global_account_data(Raw::from_json_string(json!({
                        "type": event_type, "content": {"rooms": {source_id.as_str(): {state_key: {}}}}
                    }).to_string()).unwrap());
                }
            })
            .await;
        let room = client.get_room(target_id).unwrap();
        let packs = super::get_sticker_packs(&client, &room).await.unwrap();
        assert_eq!(
            packs
                .iter()
                .map(|pack| pack.title.as_str())
                .collect::<Vec<_>>(),
            ["new", "old"]
        );
    }
}
