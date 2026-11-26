// The record adapters (0054, Adapters) and the rules every provider applies through them: the members a store has no
// place for ride on the base, approval-required members wait for the person, and a team's contested records wait for
// Keep Mine or Keep Theirs.
#![expect(
    clippy::disallowed_types,
    clippy::disallowed_methods,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]

pub mod approval;
pub mod carry;
pub mod categories;
pub mod conflict;
pub mod fields;
pub mod history;
pub mod library;
pub mod saved_queries;
pub mod settings;
pub mod store_journal;
pub mod team_library;
pub mod unsettled;

use std::collections::BTreeSet;

use serde_json::Value;
use tablepro_records::Kind;

use crate::api::adapter::{LocalChange, RecordAdapter, StoreStamp};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::ScopeName;

// The stores' calls block on files and SQLite, so they run off the runtime's workers.
pub(crate) async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T, AdapterError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| AdapterError::Store {
            store: "blocking task".to_owned(),
            detail: error.to_string(),
        })
}

// A store's copy as it goes up and as a merge reads the device's side: the members the store cannot hold put back
// from the base, the base's value in each member the store holds as it reads the base's (`unsettled::reading`), and
// the base's value in each member the device keeps to itself or that waits for the person.
pub fn local_view(
    kind: Kind,
    scope: ScopeName,
    stored: &Value,
    base: Option<&Value>,
    held: &BTreeSet<String>,
) -> Value {
    let carried = carry::carried(kind, stored, base);
    let read = unsettled::read(kind, &carried, base);
    fields::with_members_of(kind, scope, &read, base, held)
}

// What a pull's store write took: the identity after the last write that landed, and the changes the store refused.
pub(crate) struct Applied<T> {
    pub(crate) stamp: Option<StoreStamp>,
    pub(crate) refused: Vec<T>,
}

// A pull's changes to one store in one write. A store that cannot keep a value refuses the whole write, so each change
// then goes alone: the ones it keeps land, and the ones it refuses come back for the caller to hold by id, as a record
// this build cannot read is held (0054, Rules for both providers), so one record never stops every later change. Any
// other failure stops the write as before. `check` runs before each write.
pub(crate) async fn apply_keeping<T>(
    adapter: &dyn RecordAdapter,
    scope: ScopeName,
    changes: Vec<(T, LocalChange)>,
    check: impl Fn() -> Result<(), SyncError>,
) -> Result<Applied<T>, SyncError> {
    let (tags, batch): (Vec<T>, Vec<LocalChange>) = changes.into_iter().unzip();
    check()?;
    match adapter.apply(scope, batch.clone()).await {
        Ok(stamp) => {
            return Ok(Applied {
                stamp: Some(stamp),
                refused: Vec::new(),
            });
        }
        Err(AdapterError::Unreadable { .. }) if tags.len() == 1 => {
            return Ok(Applied {
                stamp: None,
                refused: tags,
            });
        }
        Err(AdapterError::Unreadable { .. }) => {}
        Err(other) => return Err(other.into()),
    }
    let mut applied = Applied {
        stamp: None,
        refused: Vec::new(),
    };
    for (tag, change) in tags.into_iter().zip(batch) {
        check()?;
        match adapter.apply(scope, vec![change]).await {
            Ok(stamp) => applied.stamp = Some(stamp),
            Err(AdapterError::Unreadable { .. }) => applied.refused.push(tag),
            Err(other) => return Err(other.into()),
        }
    }
    Ok(applied)
}
