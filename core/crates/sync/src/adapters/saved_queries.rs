// The `saved_query` and `saved_query_folder` kinds (0051, Kinds; 0052, Saved queries, folders and history in the core)
// over the core's saved queries in `history.db`. Ids and references are upper-case UUIDs, a reference nothing answers
// to reads as the top level, and times are whole milliseconds. A write that puts two records in one place under one
// name or one keyword is settled by the store, the record created first keeping it (0052, Collisions); the store's
// copy of each loser then differs from its base, so the next push sends the release as this device's own edit, as the
// Swift engines' `SavedQueryKeywordResolver` did.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::record_id::{parse_uuid, uuid_id};
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{QueryHistory, SavedQueryFolder, SavedQueryWrite, StorageError};
use uuid::Uuid;

use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

// The file every kind of the history database belongs to, so restoring it refills them together (0060).
pub const HISTORY_STORE: &str = "history.db";

pub(crate) fn store_error(error: StorageError) -> AdapterError {
    AdapterError::Store {
        store: HISTORY_STORE.to_owned(),
        detail: error.to_string(),
    }
}

pub(crate) async fn history_identity(history: &QueryHistory) -> Result<StoreStamp, AdapterError> {
    let identity = history.identity().await.map_err(store_error)?;
    Ok(StoreStamp {
        generation: identity.generation,
        sequence: identity.sequence,
    })
}

pub(crate) fn unreadable(detail: &str) -> AdapterError {
    AdapterError::Unreadable {
        detail: detail.to_owned(),
    }
}

pub(crate) fn millis(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(elapsed) => i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX),
        Err(error) => i64::try_from(error.duration().as_millis()).map_or(i64::MIN, |millis| -millis),
    }
}

pub(crate) fn from_millis(millis: i64) -> SystemTime {
    let span = Duration::from_millis(millis.unsigned_abs());
    let time = if millis >= 0 {
        UNIX_EPOCH.checked_add(span)
    } else {
        UNIX_EPOCH.checked_sub(span)
    };
    time.unwrap_or(UNIX_EPOCH)
}

pub(crate) fn record_uuid(record_id: &str) -> Result<Uuid, AdapterError> {
    parse_uuid(record_id).ok_or_else(|| unreadable("a record id that is not an upper-case UUID"))
}

// A member the record may leave out; one of the wrong type is no copy this build can hold.
pub(crate) fn optional<'a, T>(
    fields: &'a Value,
    member: &str,
    read: impl FnOnce(&'a Value) -> Option<T>,
) -> Result<Option<T>, AdapterError> {
    match fields.get(member) {
        None => Ok(None),
        Some(value) => read(value)
            .map(Some)
            .ok_or_else(|| unreadable("a member of the wrong type")),
    }
}

pub(crate) fn text(fields: &Value, member: &str) -> Result<Option<String>, AdapterError> {
    optional(fields, member, |value| value.as_str().map(str::to_owned))
}

pub(crate) fn integer(fields: &Value, member: &str) -> Result<Option<i64>, AdapterError> {
    optional(fields, member, Value::as_i64)
}

pub(crate) fn reference(fields: &Value, member: &str) -> Result<Option<Uuid>, AdapterError> {
    match text(fields, member)? {
        None => Ok(None),
        Some(id) => parse_uuid(&id)
            .map(Some)
            .ok_or_else(|| unreadable("a reference that is not an upper-case UUID")),
    }
}

fn required(fields: &Value, member: &str) -> Result<String, AdapterError> {
    text(fields, member)?.ok_or_else(|| unreadable("a required member is missing"))
}

// A copy written before its times were kept takes the time it arrives, as the Mac's decoder gives it.
fn time(fields: &Value, member: &str, now: SystemTime) -> Result<SystemTime, AdapterError> {
    Ok(integer(fields, member)?.map_or(now, from_millis))
}

fn put(fields: &mut Value, member: &str, value: Option<Value>) {
    if let Some(value) = value {
        fields[member] = value;
    }
}

pub fn query_fields(query: &SavedQuery) -> Value {
    let mut fields = json!({
        "name": query.name,
        "query": query.query,
        "sort_order": query.order,
        "created_at": millis(query.created_at),
        "updated_at": millis(query.updated_at),
    });
    put(&mut fields, "keyword", query.keyword.clone().map(Value::String));
    put(
        &mut fields,
        "connection_id",
        query.connection_id.map(|id| Value::String(uuid_id(id))),
    );
    put(
        &mut fields,
        "folder_id",
        query.folder_id.map(|id| Value::String(uuid_id(id))),
    );
    fields
}

pub fn folder_fields(folder: &SavedQueryFolder) -> Value {
    let mut fields = json!({
        "name": folder.name,
        "sort_order": folder.order,
        "created_at": millis(folder.created_at),
        "updated_at": millis(folder.updated_at),
    });
    put(
        &mut fields,
        "connection_id",
        folder.connection_id.map(|id| Value::String(uuid_id(id))),
    );
    put(
        &mut fields,
        "parent_id",
        folder.parent_id.map(|id| Value::String(uuid_id(id))),
    );
    fields
}

// The connection's name is a display copy that never syncs: a query the store holds keeps its own.
pub fn query_from(
    record_id: &str,
    fields: &Value,
    held: Option<&SavedQuery>,
    now: SystemTime,
) -> Result<SavedQuery, AdapterError> {
    Ok(SavedQuery {
        id: record_uuid(record_id)?,
        name: required(fields, "name")?,
        query: required(fields, "query")?,
        connection_id: reference(fields, "connection_id")?,
        connection_name: held.map(|query| query.connection_name.clone()).unwrap_or_default(),
        keyword: text(fields, "keyword")?,
        folder_id: reference(fields, "folder_id")?,
        order: integer(fields, "sort_order")?.unwrap_or(0),
        created_at: time(fields, "created_at", now)?,
        updated_at: time(fields, "updated_at", now)?,
    })
}

pub fn folder_from(record_id: &str, fields: &Value, now: SystemTime) -> Result<SavedQueryFolder, AdapterError> {
    Ok(SavedQueryFolder {
        id: record_uuid(record_id)?,
        connection_id: reference(fields, "connection_id")?,
        name: required(fields, "name")?,
        parent_id: reference(fields, "parent_id")?,
        order: integer(fields, "sort_order")?.unwrap_or(0),
        created_at: time(fields, "created_at", now)?,
        updated_at: time(fields, "updated_at", now)?,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Held {
    Queries,
    Folders,
}

pub struct SavedQueryAdapter {
    history: QueryHistory,
    held: Held,
}

impl SavedQueryAdapter {
    // One adapter per kind over the one store.
    pub fn all(history: &QueryHistory) -> Vec<Arc<dyn RecordAdapter>> {
        [Held::Queries, Held::Folders]
            .into_iter()
            .map(|held| {
                Arc::new(Self {
                    history: history.clone(),
                    held,
                }) as Arc<dyn RecordAdapter>
            })
            .collect()
    }

    fn write(&self, changes: Vec<LocalChange>, held: &[SavedQuery]) -> Result<SavedQueryWrite, AdapterError> {
        let now = SystemTime::now();
        let held: HashMap<Uuid, &SavedQuery> = held.iter().map(|query| (query.id, query)).collect();
        let mut write = SavedQueryWrite::default();
        for change in changes {
            match (self.held, change) {
                (Held::Queries, LocalChange::Put { record_id, fields }) => {
                    let id = record_uuid(&record_id)?;
                    let held = held.get(&id).copied();
                    write.queries.push(query_from(&record_id, &fields, held, now)?);
                }
                (Held::Folders, LocalChange::Put { record_id, fields }) => {
                    write.folders.push(folder_from(&record_id, &fields, now)?);
                }
                (Held::Queries, LocalChange::Delete { record_id }) => {
                    write.removed_queries.push(record_uuid(&record_id)?);
                }
                (Held::Folders, LocalChange::Delete { record_id }) => {
                    write.removed_folders.push(record_uuid(&record_id)?);
                }
            }
        }
        Ok(write)
    }
}

#[async_trait]
impl RecordAdapter for SavedQueryAdapter {
    fn kind(&self) -> Kind {
        match self.held {
            Held::Queries => Kind::SavedQuery,
            Held::Folders => Kind::SavedQueryFolder,
        }
    }

    fn store(&self) -> &str {
        HISTORY_STORE
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        history_identity(&self.history).await
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::Personal {
            return Ok(LocalRecords::default());
        }
        let contents = self.history.saved_queries().contents().await.map_err(store_error)?;
        let records = match self.held {
            Held::Queries => contents
                .queries
                .iter()
                .map(|query| (query.id, query_fields(query)))
                .collect::<Vec<_>>(),
            Held::Folders => contents
                .folders
                .iter()
                .map(|folder| (folder.id, folder_fields(folder)))
                .collect(),
        };
        Ok(LocalRecords {
            records: records
                .into_iter()
                .map(|(id, fields)| LocalRecord {
                    record_id: uuid_id(id),
                    fields,
                    standing: Standing::Syncs,
                })
                .collect(),
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        })
    }

    // Each record as the pull settled it, under its own id: a removed folder moves no query, since each record the
    // other device's deletion moved comes as its own change. A copy the store cannot hold refuses the whole write, so
    // no base is kept for a record the store lacks.
    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal || changes.is_empty() {
            return self.identity().await;
        }
        let store = self.history.saved_queries();
        let held = match self.held {
            Held::Queries => store.contents().await.map_err(store_error)?.queries,
            Held::Folders => Vec::new(),
        };
        let write = self.write(changes, &held)?;
        store.write(&write).await.map_err(|error| match error {
            StorageError::EmptyName | StorageError::TooLarge { .. } => unreadable("a copy the store refuses"),
            other => store_error(other),
        })?;
        self.identity().await
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

#[cfg(test)]
#[path = "saved_queries_tests.rs"]
mod tests;
