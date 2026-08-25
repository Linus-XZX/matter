// Copyright 2024 The Matrix.org Foundation C.I.C.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// A module for building a [`RoomIndex`]
pub mod builder;

use std::{
    collections::{HashMap, HashSet},
    fmt,
};

use once_cell::sync::OnceCell;
use ruma::{
    EventId, OwnedEventId, OwnedRoomId, RoomId,
    events::room::message::{OriginalSyncRoomMessageEvent, Relation},
};
use tantivy::{
    DateTime, Index, IndexReader, Order, ReloadPolicy, TantivyDocument, collector::TopDocs,
    directory::error::OpenDirectoryError, query::QueryParser, schema::Value,
};
use tracing::{debug, error, warn};

use crate::{
    OpStamp, TANTIVY_INDEX_MEMORY_BUDGET,
    error::IndexError,
    schema::{MatrixSearchIndexSchema, RoomMessageSchema},
    writer::SearchIndexWriter,
};

/// A struct to represent the operations on a [`RoomIndex`]
#[derive(Debug, Clone)]
pub enum RoomIndexOperation {
    /// Add this event to the index.
    Add(OriginalSyncRoomMessageEvent),
    /// Remove all documents in the index where
    /// `MatrixSearchIndexSchema::deletion_key()` matches this event id.
    Remove(OwnedEventId),
    /// Replace all documents in the index where
    /// `MatrixSearchIndexSchema::deletion_key()` matches this event id with
    /// the new event.
    Edit(OwnedEventId, OriginalSyncRoomMessageEvent),
    /// Do nothing.
    Noop,
}

/// A struct that holds all data pertaining to a particular room's
/// message index.
pub struct RoomIndex {
    index: Index,
    schema: RoomMessageSchema,
    query_parser: QueryParser,
    room_id: OwnedRoomId,
    uncommitted_adds: HashMap<OwnedEventId, OwnedEventId>,
    uncommitted_removes: HashSet<OwnedEventId>,
    reader: OnceCell<IndexReader>,
}

/// Run a closure that performs blocking I/O either on the Tokio blocking thread
/// pool (if called from within a Tokio runtime) or directly on the current
/// thread (e.g. in unit tests that do not set up a runtime).
fn block_in_place_or_direct<T>(f: impl FnOnce() -> T) -> T {
    match tokio::runtime::Handle::try_current() {
        Ok(_) => tokio::task::block_in_place(f),
        Err(_) => f(),
    }
}

impl fmt::Debug for RoomIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RoomIndex")
            .field("schema", &self.schema)
            .field("room_id", &self.room_id)
            .finish()
    }
}

impl RoomIndex {
    pub(crate) fn new_with(index: Index, schema: RoomMessageSchema, room_id: &RoomId) -> RoomIndex {
        let query_parser = QueryParser::for_index(&index, schema.default_search_fields());
        Self {
            index,
            schema,
            query_parser,
            room_id: room_id.to_owned(),
            uncommitted_adds: HashMap::new(),
            uncommitted_removes: HashSet::new(),
            reader: OnceCell::new(),
        }
    }

    /// Get a [`SearchIndexWriter`] for this index.
    fn get_writer(&self) -> Result<SearchIndexWriter, IndexError> {
        let writer = self.index.writer(TANTIVY_INDEX_MEMORY_BUDGET)?;
        Ok(SearchIndexWriter::new(writer, self.schema.clone()))
    }

    /// Get a [`IndexReader`] for this index.
    fn reader(&self) -> Result<&IndexReader, IndexError> {
        self.reader.get_or_try_init(|| {
            Ok(self
                .index
                .reader_builder()
                .reload_policy(ReloadPolicy::Manual)
                .try_into()?)
        })
    }

    /// Commit added events to [`RoomIndex`]. The changes are not reflected in
    /// the search results until the serchers are reloaded.
    ///
    /// Use [`RoomIndex::commit_and_reload`] for this purpose.
    fn commit(&mut self, writer: &mut SearchIndexWriter) -> Result<OpStamp, IndexError> {
        let last_commit_opstamp = writer.commit()?; // TODO: This is blocking. Handle it.
        self.uncommitted_adds.clear();
        self.uncommitted_removes.clear();
        Ok(last_commit_opstamp)
    }

    /// Commit added events to [`RoomIndex`] and
    /// update searchers so that they reflect the state of the last
    /// `.commit()`.
    ///
    /// Every commit should be rapidly reflected on your `IndexReader` and you
    /// should not need to call `reload()` at all.
    ///
    /// This automatic reload can take 10s of milliseconds to kick in however,
    /// and in unit tests it can be nice to deterministically force the
    /// reload of searchers.
    fn commit_and_reload(&mut self, writer: &mut SearchIndexWriter) -> Result<OpStamp, IndexError> {
        debug!(
            "RoomIndex: committing and reloading: uncommitted: {:?}, {:?}",
            self.uncommitted_adds, self.uncommitted_removes
        );
        let last_commit_opstamp = self.commit(writer)?;
        self.reader()?.reload()?;
        Ok(last_commit_opstamp)
    }

    /// Search the [`RoomIndex`] for some query, newest event first. Returns a
    /// list of results with a maximum given length. If `pagination_offset` is
    /// set then the results will start there, i.e.
    ///
    /// if `max_number_of_results = 3` and `pagination_offset = 10`
    /// (and there are a surplus of results)
    /// then this will return results `11, 12, 13`
    pub fn search(
        &self,
        query: &str,
        max_number_of_results: usize,
        pagination_offset: Option<usize>,
    ) -> Result<Vec<OwnedEventId>, IndexError> {
        let query = self.query_parser.parse_query(query)?;
        let searcher = self.reader()?.searcher();

        let offset = pagination_offset.unwrap_or(0);

        let results = searcher.search(
            &query,
            &TopDocs::with_limit(max_number_of_results)
                .and_offset(offset)
                .order_by_fast_field::<DateTime>(
                    self.schema.get_field_name(self.schema.date_field()),
                    Order::Desc,
                ),
        )?;
        let mut ret: Vec<OwnedEventId> = Vec::new();
        let pk = self.schema.primary_key();

        for (_date, doc_address) in results {
            let retrieved_doc: TantivyDocument = searcher.doc(doc_address)?;
            match retrieved_doc
                .get_first(pk)
                .and_then(|maybe_value| maybe_value.as_str())
            {
                Some(value) => match OwnedEventId::try_from(value) {
                    Ok(event_id) => ret.push(event_id),
                    Err(err) => error!("error while parsing event_id from search result: {err:?}"),
                },
                _ => error!("unexpected value type while searching documents"),
            }
        }

        Ok(ret)
    }

    fn get_events_to_be_removed(
        &self,
        event_id: &EventId,
    ) -> Result<Vec<OwnedEventId>, IndexError> {
        self.search(
            format!(
                "{}:\"{}\"",
                self.schema.get_field_name(self.schema.deletion_key()),
                escape_event_id_for_query(event_id.as_str())
            )
            .as_str(),
            10000,
            None,
        )
    }

    fn add(
        &mut self,
        writer: &mut SearchIndexWriter,
        event: OriginalSyncRoomMessageEvent,
    ) -> Result<(), IndexError> {
        let deletion_key = match &event.content.relates_to {
            Some(Relation::Replacement(replacement)) => replacement.event_id.clone(),
            _ => event.event_id.clone(),
        };
        if !self.contains(&event.event_id)? {
            writer.add(self.schema.make_doc(event.clone())?)?;
        }
        self.uncommitted_removes.remove(&event.event_id);
        self.uncommitted_adds.insert(event.event_id, deletion_key);
        Ok(())
    }

    fn remove(
        &mut self,
        writer: &mut SearchIndexWriter,
        event_id: OwnedEventId,
    ) -> Result<(), IndexError> {
        let events = self.get_events_to_be_removed(&event_id)?;

        writer.remove(&event_id);

        for event in events.into_iter() {
            self.uncommitted_adds.remove(&event);
            self.uncommitted_removes.insert(event);
        }

        let uncommitted = self
            .uncommitted_adds
            .iter()
            .filter(|(_, deletion_key)| **deletion_key == event_id)
            .map(|(primary_key, _)| primary_key.clone())
            .collect::<Vec<_>>();
        for event in uncommitted {
            self.uncommitted_adds.remove(&event);
            self.uncommitted_removes.insert(event);
        }

        Ok(())
    }

    fn execute_impl(
        &mut self,
        writer: &mut SearchIndexWriter,
        operation: &RoomIndexOperation,
    ) -> Result<(), IndexError> {
        debug!("INDEX: executing {operation:?}");
        match operation.clone() {
            RoomIndexOperation::Add(event) => {
                self.add(writer, event)?;
            }
            RoomIndexOperation::Remove(event_id) => {
                self.remove(writer, event_id)?;
            }
            RoomIndexOperation::Edit(remove_event_id, event) => {
                self.remove(writer, remove_event_id)?;
                self.add(writer, event)?;
            }
            RoomIndexOperation::Noop => {}
        }
        Ok(())
    }

    /// Execute [`RoomIndexOperation`] with retry
    fn execute_with_retry(
        &mut self,
        writer: &mut SearchIndexWriter,
        operation: &RoomIndexOperation,
        retries: usize,
    ) -> Result<(), IndexError> {
        let mut num_tries = 0;

        while let Err(err) = self.execute_impl(writer, operation) {
            if num_tries == retries {
                return Err(err);
            }
            match err {
                // Retry
                IndexError::TantivyError(_)
                | IndexError::IndexSchemaError(_)
                | IndexError::IndexWriteError(_)
                | IndexError::IO(_) => {
                    num_tries += 1;
                }
                IndexError::OpenDirectoryError(ref e) => match e {
                    // Retry
                    OpenDirectoryError::IoError {
                        io_error: _,
                        directory_path: _,
                    } => {
                        num_tries += 1;
                    }
                    // Bubble
                    OpenDirectoryError::DoesNotExist(_)
                    | OpenDirectoryError::FailedToCreateTempDir(_)
                    | OpenDirectoryError::NotADirectory(_) => return Err(err),
                },
                // Bubble
                IndexError::QueryParserError(_) => return Err(err),
                // Ignore
                IndexError::CannotIndexRedactedMessage
                | IndexError::EmptyMessage
                | IndexError::MessageTypeNotSupported => break,
            }
            debug!("Failed to execute operation in room index (try {num_tries}): {err}");
        }
        Ok(())
    }

    /// Execute [`RoomIndexOperation`]
    ///
    /// If an error occurs, retry 5 times if possible.
    ///
    /// This which will add/remove/edit an event in the index based on the
    /// operation.
    ///
    /// Prefer [`RoomIndex::bulk_execute`] for multiple operations.
    ///
    /// # Blocking behavior
    ///
    /// This method performs blocking I/O (Tantivy commit, reader reload, and
    /// merge worker synchronization). When called from within a Tokio runtime it
    /// runs that work on the blocking thread pool via
    /// [`tokio::task::block_in_place`]; otherwise it runs on the current thread.
    /// Callers should invoke it from a multi-thread Tokio runtime to avoid
    /// blocking async worker threads.
    pub fn execute(&mut self, operation: RoomIndexOperation) -> Result<(), IndexError> {
        block_in_place_or_direct(|| {
            let mut writer = self.get_writer()?;
            self.execute_with_retry(&mut writer, &operation, 5)?;
            self.commit_and_reload(&mut writer)?;
            writer.wait_merging_threads()?;
            Ok(())
        })
    }

    /// Bulk execute [`RoomIndexOperation`]s
    ///
    /// If an error occurs in the batch it retries 5 times if possible.
    ///
    /// This which will add/remove/edit an events in the index based on the
    /// operations.
    ///
    /// # Blocking behavior
    ///
    /// Like [`RoomIndex::execute`], this method performs blocking I/O and uses
    /// [`tokio::task::block_in_place`] when a Tokio runtime is present.
    pub fn bulk_execute(&mut self, operations: Vec<RoomIndexOperation>) -> Result<(), IndexError> {
        block_in_place_or_direct(|| {
            let mut writer = self.get_writer()?;
            let mut operations = operations.into_iter();
            let mut next_operation = operations.next();

            while let Some(ref operation) = next_operation {
                self.execute_with_retry(&mut writer, operation, 5)?;
                next_operation = operations.next();
            }

            self.commit_and_reload(&mut writer)?;
            writer.wait_merging_threads()?;

            Ok(())
        })
    }

    fn contains(&self, event_id: &EventId) -> Result<bool, IndexError> {
        let search_result = self.search(
            format!(
                "{}:\"{}\"",
                self.schema.get_field_name(self.schema.primary_key()),
                escape_event_id_for_query(event_id.as_str())
            )
            .as_str(),
            1,
            None,
        );
        match search_result {
            Ok(results) => Ok(!self.uncommitted_removes.contains(event_id)
                && (!results.is_empty() || self.uncommitted_adds.contains_key(event_id))),
            Err(err) => {
                warn!("Failed to check if event has been indexed: {err}");
                Err(err)
            }
        }
    }
}

/// Escape characters inside an event id that have special meaning to Tantivy's
/// query parser (`"` and `\`). Matrix event ids do not contain these in
/// practice, but escaping them ensures a malformed id cannot break the query.
fn escape_event_id_for_query(event_id: &str) -> String {
    event_id.replace('\\', "\\\\").replace('\"', "\\\"")
}

#[cfg(test)]
mod tests {
    use std::{collections::HashSet, error::Error};

    use matrix_sdk_test::event_factory::EventFactory;
    use ruma::{
        EventId, event_id,
        events::{
            AnySyncMessageLikeEvent,
            room::message::{OriginalSyncRoomMessageEvent, RoomMessageEventContentWithoutRelation},
        },
        room_id, user_id,
    };

    use crate::{
        error::IndexError,
        index::{RoomIndex, RoomIndexOperation, builder::RoomIndexBuilder},
    };

    /// Helper function to add a regular message to the index
    ///
    /// # Panic
    /// Panics when event is not a [`OriginalSyncRoomMessageEvent`] with no
    /// relations.
    fn index_message(
        index: &mut RoomIndex,
        event: AnySyncMessageLikeEvent,
    ) -> Result<(), IndexError> {
        if let AnySyncMessageLikeEvent::RoomMessage(ev) = event
            && let Some(ev) = ev.as_original()
            && ev.content.relates_to.is_none()
        {
            return index.execute(RoomIndexOperation::Add(ev.clone()));
        }
        panic!("Event was not a relationless OriginalSyncRoomMessageEvent.")
    }

    /// Helper function to remove events to the index
    fn index_remove(index: &mut RoomIndex, event_id: &EventId) -> Result<(), IndexError> {
        index.execute(RoomIndexOperation::Remove(event_id.to_owned()))
    }

    /// Helper function to edit events in index
    ///
    /// Edit event with `event_id` into new [`OriginalSyncRoomMessageEvent`]
    fn index_edit(
        index: &mut RoomIndex,
        event_id: &EventId,
        new: OriginalSyncRoomMessageEvent,
    ) -> Result<(), IndexError> {
        index.execute(RoomIndexOperation::Edit(event_id.to_owned(), new))
    }

    #[test]
    fn test_add_event() {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event = EventFactory::new()
            .text_msg("event message")
            .event_id(event_id!("$event_id:localhost"))
            .room(room_id)
            .sender(user_id!("@user_id:localhost"))
            .into_any_sync_message_like_event();

        index_message(&mut index, event).expect("failed to add event: {res:?}");
    }

    #[test]
    fn test_cjk_substring_ngram_search() {
        let room_id = room_id!("!room_id:localhost");
        let event_id = event_id!("$event_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();
        let event = EventFactory::new()
            .text_msg("今晚八点开会")
            .event_id(event_id)
            .room(room_id)
            .sender(user_id!("@user_id:localhost"))
            .into_any_sync_message_like_event();
        index_message(&mut index, event).expect("failed to add event");

        let results = index
            .search("body_ngram:\"八点\"", 10, None)
            .expect("CJK substring search failed");

        assert_eq!(results, [event_id.to_owned()]);
    }

    #[test]
    fn test_encrypted_index_survives_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let room_id = room_id!("!room_id:localhost");
        let event_id = event_id!("$persistent:localhost");
        {
            let mut index = RoomIndexBuilder::new_on_disk(directory.path().to_path_buf(), room_id)
                .encrypted("device-secret")
                .build()
                .unwrap();
            let event = EventFactory::new()
                .text_msg("持久搜索消息")
                .event_id(event_id)
                .room(room_id)
                .sender(user_id!("@user_id:localhost"))
                .into_any_sync_message_like_event();
            index_message(&mut index, event).unwrap();
        }

        let index = RoomIndexBuilder::new_on_disk(directory.path().to_path_buf(), room_id)
            .encrypted("device-secret")
            .build()
            .unwrap();
        let results = index.search("body_ngram:\"搜索\"", 10, None).unwrap();

        assert_eq!(results, [event_id.to_owned()]);
    }

    #[test]
    fn test_8000_message_query_stays_below_one_second() {
        let directory = tempfile::tempdir().unwrap();
        let room_id = room_id!("!room_id:localhost");
        let sender = user_id!("@user_id:localhost");
        let factory = EventFactory::new().room(room_id).sender(sender);
        let operations = (0..8_000)
            .map(|position| {
                let event_id = EventId::parse(format!("$event{position}:localhost")).unwrap();
                let body = if position % 1_000 == 0 {
                    format!("第 {position} 条歇逼消息")
                } else {
                    format!("第 {position} 条普通消息")
                };
                let event = factory
                    .text_msg(body)
                    .event_id(&event_id)
                    .into_any_sync_message_like_event();
                let AnySyncMessageLikeEvent::RoomMessage(event) = event else {
                    unreachable!();
                };
                RoomIndexOperation::Add(event.as_original().unwrap().clone())
            })
            .collect();
        {
            let mut index = RoomIndexBuilder::new_on_disk(directory.path().to_path_buf(), room_id)
                .encrypted("device-secret")
                .build()
                .unwrap();
            index.bulk_execute(operations).unwrap();
        }
        let index = RoomIndexBuilder::new_on_disk(directory.path().to_path_buf(), room_id)
            .encrypted("device-secret")
            .build()
            .unwrap();

        let started = std::time::Instant::now();
        let results = index.search("body_ngram:\"歇逼\"", 30, None).unwrap();
        let query_elapsed = started.elapsed();

        assert_eq!(results.len(), 8);
        assert!(
            query_elapsed < std::time::Duration::from_secs(1),
            "8k-message local query took {:?}",
            query_elapsed
        );
        eprintln!("local query took {query_elapsed:?}");
    }

    #[test]
    fn test_reader_is_cached_and_pagination_uses_raw_offset() {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();
        let user_id = user_id!("@user_id:localhost");
        let factory = EventFactory::new().room(room_id).sender(user_id);
        for event_id in ["$one:localhost", "$two:localhost", "$three:localhost"] {
            let event_id = EventId::parse(event_id).unwrap();
            index_message(
                &mut index,
                factory
                    .text_msg("shared search term")
                    .event_id(&event_id)
                    .into_any_sync_message_like_event(),
            )
            .unwrap();
        }

        let first_reader = index.reader().unwrap();
        let second_reader = index.reader().unwrap();
        assert!(std::ptr::eq(first_reader, second_reader));

        let first_page = index.search("shared", 2, None).unwrap();
        let second_page = index.search("shared", 2, Some(2)).unwrap();
        let all = first_page
            .into_iter()
            .chain(second_page)
            .collect::<HashSet<_>>();
        assert_eq!(all.len(), 3);
    }

    #[test]
    fn test_search_orders_recent_events_before_applying_offset() {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();
        let factory = EventFactory::new()
            .room(room_id)
            .sender(user_id!("@user_id:localhost"));
        for (event_id, timestamp) in [
            (event_id!("$oldest:localhost"), 10),
            (event_id!("$newest:localhost"), 30),
            (event_id!("$middle:localhost"), 20),
        ] {
            index_message(
                &mut index,
                factory
                    .text_msg("shared search term")
                    .event_id(event_id)
                    .server_ts(timestamp)
                    .into_any_sync_message_like_event(),
            )
            .unwrap();
        }

        assert_eq!(
            index.search("shared", 2, None).unwrap(),
            [
                event_id!("$newest:localhost").to_owned(),
                event_id!("$middle:localhost").to_owned(),
            ]
        );
        assert_eq!(
            index.search("shared", 2, Some(2)).unwrap(),
            [event_id!("$oldest:localhost").to_owned()]
        );
    }

    #[test]
    fn test_bulk_add_then_edit_keeps_only_the_edit() {
        let room_id = room_id!("!room_id:localhost");
        let old_event_id = event_id!("$old_event_id:localhost");
        let new_event_id = event_id!("$new_event_id:localhost");
        let factory = EventFactory::new()
            .room(room_id)
            .sender(user_id!("@user_id:localhost"));
        let original = factory
            .text_msg("old searchable body")
            .event_id(old_event_id)
            .into_original_sync_room_message_event();
        let edit = factory
            .text_msg("new searchable body")
            .edit(
                old_event_id,
                RoomMessageEventContentWithoutRelation::text_plain("new searchable body"),
            )
            .event_id(new_event_id)
            .into_original_sync_room_message_event();
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        index
            .bulk_execute(vec![
                RoomIndexOperation::Add(original),
                RoomIndexOperation::Edit(old_event_id.to_owned(), edit),
            ])
            .unwrap();

        assert!(index.search("old", 10, None).unwrap().is_empty());
        assert_eq!(
            index.search("new", 10, None).unwrap(),
            [new_event_id.to_owned()]
        );
    }

    #[test]
    fn test_search_populated_index() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event_id_1 = event_id!("$event_id_1:localhost");
        let event_id_2 = event_id!("$event_id_2:localhost");
        let event_id_3 = event_id!("$event_id_3:localhost");
        let user_id = user_id!("@user_id:localhost");
        let f = EventFactory::new().room(room_id).sender(user_id);

        index_message(
            &mut index,
            f.text_msg("This is a sentence")
                .event_id(event_id_1)
                .into_any_sync_message_like_event(),
        )?;

        index_message(
            &mut index,
            f.text_msg("All new words")
                .event_id(event_id_2)
                .into_any_sync_message_like_event(),
        )?;

        index_message(
            &mut index,
            f.text_msg("A similar sentence")
                .event_id(event_id_3)
                .into_any_sync_message_like_event(),
        )?;

        let result = index
            .search("sentence", 10, None)
            .expect("search failed with: {result:?}");
        let result: HashSet<_> = result.iter().collect();

        let true_value = [event_id_1.to_owned(), event_id_3.to_owned()];
        let true_value: HashSet<_> = true_value.iter().collect();

        assert_eq!(result, true_value, "search result not correct: {result:?}");

        Ok(())
    }

    #[test]
    fn test_search_empty_index() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let index = RoomIndexBuilder::new_in_memory(room_id).build();

        let result = index
            .search("sentence", 10, None)
            .expect("search failed with: {result:?}");

        assert!(result.is_empty(), "search result not empty: {result:?}");

        Ok(())
    }

    #[test]
    fn test_escape_event_id_for_query() {
        assert_eq!(super::escape_event_id_for_query("$foo"), "$foo");
        assert_eq!(super::escape_event_id_for_query("$a\\b"), "$a\\\\b");
        assert_eq!(super::escape_event_id_for_query("$a\"b"), "$a\\\"b");
    }

    #[test]
    fn test_index_contains_false() {
        let room_id = room_id!("!room_id:localhost");
        let index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event_id = event_id!("$event_id:localhost");

        assert!(
            !index.contains(event_id).unwrap(),
            "Index should not contain event"
        );
    }

    #[test]
    fn test_index_contains_true() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event_id = event_id!("$event_id:localhost");
        let event = EventFactory::new()
            .text_msg("This is a sentence")
            .event_id(event_id)
            .room(room_id)
            .sender(user_id!("@user_id:localhost"))
            .into_any_sync_message_like_event();

        index_message(&mut index, event)?;

        assert!(
            index.contains(event_id).unwrap(),
            "Index should contain event"
        );

        Ok(())
    }

    #[test]
    fn test_index_add_idempotency() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event_id = event_id!("$event_id:localhost");
        let event = EventFactory::new()
            .text_msg("This is a sentence")
            .event_id(event_id)
            .room(room_id)
            .sender(user_id!("@user_id:localhost"))
            .into_any_sync_message_like_event();

        index_message(&mut index, event.clone())?;

        assert!(
            index.contains(event_id).unwrap(),
            "Index should contain event"
        );

        // indexing again should do nothing
        index_message(&mut index, event)?;

        assert!(
            index.contains(event_id).unwrap(),
            "Index should still contain event"
        );

        let result = index
            .search("sentence", 10, None)
            .expect("search failed with: {result:?}");

        assert_eq!(result.len(), 1, "Index should have ignored second indexing");

        Ok(())
    }

    #[test]
    fn test_remove_event() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let event_id = event_id!("$event_id:localhost");
        let user_id = user_id!("@user_id:localhost");
        let f = EventFactory::new().room(room_id).sender(user_id);

        let event = f
            .text_msg("This is a sentence")
            .event_id(event_id)
            .into_any_sync_message_like_event();

        index_message(&mut index, event)?;

        assert!(
            index.contains(event_id).unwrap(),
            "Index should contain event"
        );

        index_remove(&mut index, event_id)?;

        assert!(
            !index.contains(event_id).unwrap(),
            "Index should not contain event"
        );

        Ok(())
    }

    #[test]
    fn test_edit_removes_old_and_adds_new_event() -> Result<(), Box<dyn Error>> {
        let room_id = room_id!("!room_id:localhost");
        let mut index = RoomIndexBuilder::new_in_memory(room_id).build();

        let old_event_id = event_id!("$old_event_id:localhost");
        let user_id = user_id!("@user_id:localhost");
        let f = EventFactory::new().room(room_id).sender(user_id);

        let old_event = f
            .text_msg("This is a sentence")
            .event_id(old_event_id)
            .into_any_sync_message_like_event();

        index_message(&mut index, old_event)?;

        assert!(
            index.contains(old_event_id).unwrap(),
            "Index should contain event"
        );

        let new_event_id = event_id!("$new_event_id:localhost");
        let edit = f
            .text_msg("This is a brand new sentence!")
            .edit(
                old_event_id,
                RoomMessageEventContentWithoutRelation::text_plain("This is a brand new sentence!"),
            )
            .event_id(new_event_id)
            .into_original_sync_room_message_event();

        index_edit(&mut index, old_event_id, edit)?;

        assert!(
            !index.contains(old_event_id).unwrap(),
            "Index should not contain old event"
        );
        assert!(
            index.contains(new_event_id).unwrap(),
            "Index should contain edited event"
        );

        Ok(())
    }

    #[test]
    fn test_block_in_place_or_direct_without_runtime() {
        assert_eq!(super::block_in_place_or_direct(|| 42), 42);
    }

    #[test]
    fn test_block_in_place_or_direct_inside_tokio_runtime() {
        let rt = tokio::runtime::Runtime::new().expect("multi-thread runtime");
        let result = rt.block_on(async { super::block_in_place_or_direct(|| 42) });
        assert_eq!(result, 42);
    }
}
