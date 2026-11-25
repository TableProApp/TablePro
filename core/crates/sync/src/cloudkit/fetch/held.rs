// What waits by id (0054, Rules for both providers). A change held while the copy could not be read is fetched by
// name once it reads: a delta never sends it again, and starting the pull over would drop the deletions a delta still
// carries. A held deletion applies under the rules a readable record has.

use std::collections::BTreeSet;

use super::copy::{self, Incoming, kind_of, name_of};
use super::settle::{Batch, Settle, View};
use super::{Counts, Fetcher, SCOPE};
use crate::api::cloudkit::{CloudKitFailure, CloudKitFetched};
use crate::api::error::SyncError;
use crate::api::ids::RecordKey;
use crate::api::state::{HeldReason, Row, RowRange, Standing, Table};

// Under the 400 items per operation that CloudKit's `limitExceeded` documentation gives as its guideline.
const NAMES_PER_CALL: usize = 200;

#[derive(Debug, Default)]
struct Recovery {
    names: Vec<String>,
    deletions: Vec<RecordKey>,
    release: Vec<RecordKey>,
}

impl Fetcher<'_> {
    pub(super) async fn fetch_names(&self, names: Vec<String>) -> Result<Vec<CloudKitFetched>, SyncError> {
        let mut fetched = Vec::with_capacity(names.len());
        let mut calls: Vec<Vec<String>> = names.chunks(NAMES_PER_CALL).rev().map(<[String]>::to_vec).collect();
        while let Some(call) = calls.pop() {
            match self.transport.fetch_records(self.account.clone(), call.clone()).await {
                Ok(answers) => fetched.extend(answers),
                // CloudKit asks a request it finds too large to be split and sent again.
                Err(CloudKitFailure::LimitExceeded) if call.len() > 1 => {
                    let (first, second) = call.split_at(call.len() / 2);
                    calls.push(second.to_vec());
                    calls.push(first.to_vec());
                }
                Err(failure) => return Err(failure.into()),
            }
        }
        Ok(fetched)
    }

    pub(super) async fn recover(&self) -> Result<Counts, SyncError> {
        let recovery = self.recovery().await?;
        if recovery.names.is_empty() && recovery.deletions.is_empty() && recovery.release.is_empty() {
            return Ok(Counts::default());
        }
        let mut items: Vec<Incoming> = recovery.deletions.into_iter().map(Incoming::Deleted).collect();
        let mut release = recovery.release;
        let mut recovered = 0;
        for answer in self.fetch_names(recovery.names).await? {
            match answer {
                CloudKitFetched::Found { record } => {
                    if let Some(item) = copy::changed(&record) {
                        recovered += u32::from(matches!(item, Incoming::Changed(_)));
                        items.push(item);
                    }
                }
                // Gone from the zone with no deletion a delta brought: the change no longer stands.
                CloudKitFetched::Missing { name } => release.extend(copy::key_of_name(&name)),
                CloudKitFetched::Failed { .. } => {}
            }
        }
        let mut counts = self
            .settle(Batch {
                items,
                release,
                ..Batch::default()
            })
            .await?;
        counts.recovered += recovered;
        Ok(counts)
    }

    // Read in a transaction that is dropped, so nothing is written and no CloudKit call runs inside it.
    async fn recovery(&self) -> Result<Recovery, SyncError> {
        let txn = self.state.begin().await?;
        let mut settle = Settle::new(self, txn, BTreeSet::new());
        let mut recovery = Recovery::default();
        for row in settle.txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await? {
            let Row::Held(held) = row else {
                continue;
            };
            if held.reason == HeldReason::AwaitingApproval {
                continue;
            }
            // One of a category this device does not sync now stays held.
            let Some(kind) = kind_of(&held.key).filter(|kind| self.categories.syncs(*kind)) else {
                continue;
            };
            match settle.view(&held.key, kind).await? {
                View::NoAdapter | View::Unreadable(_) => {}
                _ if held.record.deleted.is_some() => recovery.deletions.push(held.key),
                View::Stored(record) if record.standing == Standing::LocalOnly => recovery.release.push(held.key),
                View::Stored(_) | View::Missing => recovery.names.extend(name_of(&held.key)),
            }
        }
        Ok(recovery)
    }
}
