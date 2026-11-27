// A save CloudKit refused with `serverRecordChanged` (0054, A push): the engine takes the server's copy the error
// carries, or fetches the record by name when it carries none, and merges it field by field against the base and the
// store as a pull does. The store then holds the merge and the base the server's copy with its system fields, so the
// next push sends the difference on the server's change tag. A save answered `unknownItem` meets the deletion rules
// the same way (D12).

use std::collections::BTreeSet;

use tablepro_records::merge::Merged;

use super::copy::{self, Incoming, kind_of};
use super::settle::{Against, Batch, Settle, View};
use super::{Fetcher, PROFILES};
use crate::api::cloudkit::{CloudKitFetched, CloudKitRecord};
use crate::api::error::SyncError;
use crate::api::ids::RecordKey;
use crate::api::state::{RowKey, Standing};

#[derive(Debug, Clone, PartialEq)]
pub struct ServerChanged {
    pub name: String,
    pub server: Option<CloudKitRecord>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Rebased {
    // Merged with the server's copy: push again.
    pub merged: Vec<String>,
    // The zone no longer holds them. The deletion rules settled them, so a content edit here goes up as a create and a
    // placement-only edit is dropped.
    pub gone: Vec<String>,
    // The server's copy could not be read; the save waits for a later pass.
    pub failed: Vec<RebaseFailure>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RebaseFailure {
    pub name: String,
    // CloudKit's per-record code, None when the copy came back but this build cannot read it.
    pub code: Option<i64>,
    pub retry_after_ms: Option<u64>,
}

impl RebaseFailure {
    const fn unread(name: String) -> Self {
        Self {
            name,
            code: None,
            retry_after_ms: None,
        }
    }
}

fn onto(server: &CloudKitRecord, items: &mut Vec<Incoming>, rebased: &mut Rebased) {
    match copy::changed(server) {
        Some(item @ Incoming::Changed(_)) => {
            items.push(item);
            rebased.merged.push(server.name.clone());
        }
        // Held by id, as a pulled copy this build cannot read is.
        Some(item) => {
            items.push(item);
            rebased.failed.push(RebaseFailure::unread(server.name.clone()));
        }
        None => rebased.failed.push(RebaseFailure::unread(server.name.clone())),
    }
}

// A profile the zone lost is not deleted here, since a deletion found late never removes one: its deletion comes
// through the changes, and until then its save keeps its base.
fn gone(name: String, items: &mut Vec<Incoming>, rebased: &mut Rebased) {
    let key = copy::key_of_name(&name);
    if let Some(key) = key.filter(|key| copy::kind_of(key).is_some_and(|kind| !PROFILES.contains(&kind))) {
        items.push(Incoming::Deleted(key));
    }
    rebased.gone.push(name);
}

impl Fetcher<'_> {
    pub async fn rebase(&self, conflicts: Vec<ServerChanged>) -> Result<Rebased, SyncError> {
        self.settle_pending().await?;
        let mut rebased = Rebased::default();
        let mut items = Vec::new();
        let mut by_name = Vec::new();
        for conflict in conflicts {
            match conflict.server {
                Some(server) if server.name == conflict.name => onto(&server, &mut items, &mut rebased),
                Some(_) => rebased.failed.push(RebaseFailure::unread(conflict.name)),
                None => by_name.push(conflict.name),
            }
        }
        let (answers, unanswered) = self.fetch_asked(by_name).await?;
        for answer in answers {
            match answer {
                CloudKitFetched::Found { record } => onto(&record, &mut items, &mut rebased),
                CloudKitFetched::Missing { name } => gone(name, &mut items, &mut rebased),
                CloudKitFetched::Failed {
                    name,
                    code,
                    retry_after_ms,
                } => rebased.failed.push(RebaseFailure {
                    name,
                    code: Some(code),
                    retry_after_ms,
                }),
            }
        }
        rebased.failed.extend(unanswered.into_iter().map(RebaseFailure::unread));
        self.settle(Batch {
            items,
            ..Batch::default()
        })
        .await?;
        Ok(rebased)
    }

    // Saves CloudKit answered `unknownItem`: the zone holds no record by those names, whatever deleted them. Each goes
    // as a deletion the zone reported, so a content edit here stays and goes up as a create, and a placement-only edit
    // goes with the record instead of bringing it back (D12).
    pub async fn lost(&self, names: Vec<String>) -> Result<Rebased, SyncError> {
        self.settle_pending().await?;
        let mut rebased = Rebased::default();
        let mut items = Vec::new();
        for name in names {
            gone(name, &mut items, &mut rebased);
        }
        self.settle(Batch {
            items,
            ..Batch::default()
        })
        .await?;
        Ok(rebased)
    }

    // Profiles the zone lost. A deletion found late never removes one, but a content edit to it still revives it, as
    // for any record (D12): its base goes, so it goes up as a create. One with no content edit keeps its base until
    // its deletion comes through the changes. Returns the profiles revived.
    pub(in crate::cloudkit) async fn revive(&self, keys: &[RecordKey]) -> Result<Vec<RecordKey>, SyncError> {
        let txn = self.state.begin().await?;
        let mut settle = Settle::new(self, txn, BTreeSet::new());
        let mut revived = Vec::new();
        for key in keys {
            let Some(kind) = kind_of(key) else {
                continue;
            };
            let View::Stored(record) = settle.view(key, kind).await? else {
                continue;
            };
            if record.standing != Standing::Syncs {
                continue;
            }
            if settle.merged(kind, key, Some(&record), None, Against::Base).await? != Merged::Deleted {
                settle.txn.delete(&RowKey::Base(key.clone())).await?;
                revived.push(key.clone());
            }
        }
        if !revived.is_empty() {
            self.check_stop()?;
            settle.txn.commit().await?;
        }
        Ok(revived)
    }
}
