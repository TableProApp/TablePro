// The `history_entry` kind (0051, Kinds; 0054, Providers, History) over the core's query history in `history.db`: one
// entry per run under its random id, its plaintext the `entry` the engine seals at push time. An entry is created once,
// so a prune by the retention drops it here and pushes nothing; only a deletion the person made goes up, from the
// tombstone the store keeps until it is pushed. The history of a Local only connection stays on the device (0051,
// What syncs), and so does every run the core's rules would have kept out of history, whichever app recorded it: an
// Apple app records through the store with no driver to read its statements, and an older build's history may hold
// one that carries a password.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use serde_json::{Value, json};
use tablepro_core::sql_syntax::{HistoryRecording, SqlGrammar};
use tablepro_records::Kind;
use tablepro_records::record_id::{self, uuid_id};
use tablepro_storage::QueryHistory;
use tablepro_storage::query_history::{Entry, MAX_QUERY_BYTES, NewEntry, Outcome};
use uuid::Uuid;

use super::blocking;
use super::saved_queries::{
    HISTORY_STORE, from_millis, history_identity, integer, millis, optional, record_uuid, reference, store_error, text,
    unreadable,
};
use super::settings::ConnectionStanding;
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

pub struct HistoryAdapter {
    history: QueryHistory,
    connections: Arc<dyn ConnectionStanding>,
    // Each entry's verdict, by id: an entry never changes, and reading every statement on every pass would cost a lex
    // of the whole history each time.
    may_leave: Mutex<HashMap<Uuid, bool>>,
}

impl HistoryAdapter {
    pub fn new(history: QueryHistory, connections: Arc<dyn ConnectionStanding>) -> Self {
        Self {
            history,
            connections,
            may_leave: Mutex::default(),
        }
    }

    // The verdicts of these entries, read for the ones not judged before.
    async fn judged(&self, entries: &[Entry]) -> Result<HashMap<Uuid, bool>, AdapterError> {
        let mut known = self.may_leave.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let present: HashSet<Uuid> = entries.iter().map(|entry| entry.record_id).collect();
        known.retain(|id, _| present.contains(id));
        let unjudged: Vec<(Uuid, String, String)> = entries
            .iter()
            .filter(|entry| !known.contains_key(&entry.record_id))
            .map(|entry| (entry.record_id, entry.driver_id.clone(), entry.query.clone()))
            .collect();
        if !unjudged.is_empty() {
            let judged = blocking(move || {
                unjudged
                    .into_iter()
                    .map(|(id, engine, query)| (id, may_leave(&engine, &query)))
                    .collect::<Vec<_>>()
            })
            .await?;
            known.extend(judged);
        }
        self.may_leave
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone_from(&known);
        Ok(known)
    }
}

// Whether a run may leave the device: its engine's rules keep it in the history, and the core holds rules for that
// engine. One whose engine the core does not know stays, since nothing has read it for a secret.
pub fn may_leave(engine: &str, query: &str) -> bool {
    SqlGrammar::of_engine(engine).is_some_and(|grammar| grammar.history_recording(query) == HistoryRecording::Record)
}

pub fn entry_fields(entry: &Entry) -> Value {
    let mut fields = json!({
        "query": entry.query,
        "connection_id": uuid_id(entry.connection_id),
        "connection_name": entry.connection_name,
        "database_type": entry.driver_id,
        "executed_at": millis(entry.executed_at),
        "succeeded": entry.success,
        "cancelled": entry.cancelled,
    });
    if let Some(duration) = entry.duration_ms {
        fields["duration_ms"] = json!(duration);
    }
    if let Some(rows) = entry.rows_affected {
        fields["row_count"] = json!(rows);
    }
    if let Some(error) = &entry.error {
        fields["error"] = json!(error);
    }
    fields
}

fn flag(fields: &Value, member: &str) -> Result<bool, AdapterError> {
    optional(fields, member, Value::as_bool).map(Option::unwrap_or_default)
}

// None for an entry this store cannot hold: one with no connection, no time or a query past the store's cap.
pub fn entry_from(record_id: &str, fields: &Value) -> Result<Option<NewEntry>, AdapterError> {
    record_id::check(Kind::HistoryEntry, record_id).map_err(|_| unreadable("a history id that is not a UUIDv4"))?;
    let (Some(query), Some(connection_id), Some(executed_at)) = (
        text(fields, "query")?,
        reference(fields, "connection_id")?,
        integer(fields, "executed_at")?,
    ) else {
        return Ok(None);
    };
    if query.len() > MAX_QUERY_BYTES {
        return Ok(None);
    }
    let outcome = if flag(fields, "succeeded")? {
        Outcome::Success
    } else if flag(fields, "cancelled")? {
        Outcome::Cancelled
    } else {
        Outcome::Error(text(fields, "error")?.unwrap_or_default())
    };
    Ok(Some(NewEntry {
        record_id: record_uuid(record_id)?,
        query,
        driver_id: text(fields, "database_type")?.unwrap_or_default(),
        connection_id,
        connection_name: text(fields, "connection_name")?.unwrap_or_default(),
        executed_at: from_millis(executed_at),
        duration_ms: integer(fields, "duration_ms")?,
        rows_affected: integer(fields, "row_count")?,
        outcome,
    }))
}

#[async_trait]
impl RecordAdapter for HistoryAdapter {
    fn kind(&self) -> Kind {
        Kind::HistoryEntry
    }

    fn store(&self) -> &str {
        HISTORY_STORE
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        history_identity(&self.history).await
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::History {
            return Ok(LocalRecords::default());
        }
        let entries = self.history.entries().await.map_err(store_error)?;
        let tombstones = self.history.tombstones().await.map_err(store_error)?;
        let may_leave = self.judged(&entries).await?;
        Ok(LocalRecords {
            records: entries
                .iter()
                .map(|entry| LocalRecord {
                    record_id: uuid_id(entry.record_id),
                    fields: entry_fields(entry),
                    standing: match may_leave.get(&entry.record_id) {
                        Some(true) => self.connections.standing(entry.connection_id),
                        _ => Standing::LocalOnly,
                    },
                })
                .collect(),
            unreadable: Vec::new(),
            tombstones: tombstones.into_iter().map(uuid_id).collect(),
        })
    }

    // A pulled entry the store cannot hold, or that the rules keep out of history, is left out: an entry absent from
    // the store pushes nothing, so the engine lets its base go as it does after a prune. A deletion a pull brings
    // leaves no tombstone.
    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::History || changes.is_empty() {
            return self.identity().await;
        }
        let mut entries = Vec::new();
        let mut gone: Vec<Uuid> = Vec::new();
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } => match entry_from(&record_id, &fields) {
                    Ok(Some(entry)) => entries.push(entry),
                    Ok(None) | Err(_) => tracing::debug!("a pulled history entry this store cannot hold is left out"),
                },
                LocalChange::Delete { record_id } => match record_uuid(&record_id) {
                    Ok(id) => gone.push(id),
                    Err(_) => tracing::debug!("a pulled history deletion of an id this store never holds"),
                },
            }
        }
        if !gone.is_empty() {
            self.history.remove(&gone).await.map_err(store_error)?;
        }
        let entries = blocking(move || {
            entries
                .into_iter()
                .filter(|entry| may_leave(&entry.driver_id, &entry.query))
                .collect::<Vec<_>>()
        })
        .await?;
        if !entries.is_empty() {
            self.history.put(&entries).await.map_err(store_error)?;
        }
        self.identity().await
    }

    async fn tombstones_pushed(&self, scope: ScopeName, record_ids: Vec<String>) -> Result<(), AdapterError> {
        if scope != ScopeName::History {
            return Ok(());
        }
        let ids: Vec<Uuid> = record_ids.iter().filter_map(|id| record_uuid(id).ok()).collect();
        self.history.drop_tombstones(&ids).await.map_err(store_error)
    }
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod tests;
