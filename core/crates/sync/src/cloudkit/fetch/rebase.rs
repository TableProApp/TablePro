// A save CloudKit refused with `serverRecordChanged` (0054, A push): the engine takes the server's copy the error
// carries, or fetches the record by name when it carries none, and merges it field by field against the base and the
// store as a pull does. The store then holds the merge and the base the server's copy with its system fields, so the
// next push sends the difference on the server's change tag.

use super::copy::{self, Incoming};
use super::settle::Batch;
use super::{Fetcher, PROFILES};
use crate::api::cloudkit::{CloudKitFetched, CloudKitRecord};
use crate::api::error::SyncError;

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
}
