// What waits by id (0054, Rules for both providers). A change held while the copy could not be read is fetched by
// name once it reads: a delta never sends it again, and starting the pull over would drop the deletions a delta still
// carries. A held deletion applies under the rules a readable record has.

use std::collections::BTreeSet;

use tablepro_records::Kind;

use super::copy::{self, Incoming, kind_of, name_of};
use super::settle::{Batch, Settle, View};
use super::{Counts, Fetcher, SCOPE, Waited};
use crate::api::cloudkit::{CloudKitFailure, CloudKitFetched};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, RecordKey};
use crate::api::state::{HeldReason, HeldRow, Row, RowRange, Standing, Table};

// Under the 400 items per operation that CloudKit's `limitExceeded` documentation gives as its guideline.
const NAMES_PER_CALL: usize = 200;

#[derive(Debug, Default)]
struct Recovery {
    names: Vec<String>,
    deletions: Vec<RecordKey>,
    release: Vec<RecordKey>,
}

const fn answer_name(answer: &CloudKitFetched) -> &String {
    match answer {
        CloudKitFetched::Found { record } => &record.name,
        CloudKitFetched::Missing { name } | CloudKitFetched::Failed { name, .. } => name,
    }
}

// A copy that came back but does not project: it reads no better until a delta brings it changed, so it is not
// asked for again on every pass.
fn unprojectable(held: &HeldRow) -> bool {
    held.record.fields.is_none()
        && held.record.deleted.is_none()
        && matches!(&held.record.tag, ChangeTag::CloudKit(system_fields) if !system_fields.is_empty())
}

impl Fetcher<'_> {
    async fn fetch_names(&self, names: Vec<String>) -> Result<Vec<CloudKitFetched>, SyncError> {
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

    // One answer per name asked; an answer for a name nobody asked for is dropped, and the names left unanswered
    // come back with the answers.
    pub(super) async fn fetch_asked(
        &self,
        names: Vec<String>,
    ) -> Result<(Vec<CloudKitFetched>, BTreeSet<String>), SyncError> {
        let mut unanswered: BTreeSet<String> = names.iter().cloned().collect();
        let answers = self
            .fetch_names(names)
            .await?
            .into_iter()
            .filter(|answer| unanswered.remove(answer_name(answer)))
            .collect();
        Ok((answers, unanswered))
    }

    // Recovered in the same fetch as a refill, a change takes the pull as the refill did. A record CloudKit asked to
    // wait for in this fetch is not asked for again in it.
    pub(super) async fn recover(&self, pull_wins: BTreeSet<Kind>, waited: &mut Waited) -> Result<Counts, SyncError> {
        let mut recovery = self.recovery().await?;
        recovery.names.retain(|name| !waited.holds(name));
        if recovery.names.is_empty() && recovery.deletions.is_empty() && recovery.release.is_empty() {
            return Ok(Counts::default());
        }
        let mut items: Vec<Incoming> = recovery.deletions.into_iter().map(Incoming::Deleted).collect();
        let mut release = recovery.release;
        let mut recovered = 0_u32;
        let (answers, _) = self.fetch_asked(recovery.names).await?;
        for answer in answers {
            match answer {
                CloudKitFetched::Found { record } => {
                    if let Some(item) = copy::changed(&record) {
                        recovered = recovered.saturating_add(u32::from(matches!(item, Incoming::Changed(_))));
                        items.push(item);
                    }
                }
                // Gone from the zone with no deletion a delta brought: the change no longer stands.
                CloudKitFetched::Missing { name } => release.extend(copy::key_of_name(&name)),
                CloudKitFetched::Failed {
                    name,
                    code,
                    retry_after_ms,
                } => waited.note(&name, code, retry_after_ms),
            }
        }
        let mut counts = self
            .settle(Batch {
                items,
                pull_wins,
                release,
                ..Batch::default()
            })
            .await?;
        counts.recovered = counts.recovered.saturating_add(recovered);
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
            if held.reason == HeldReason::AwaitingApproval || unprojectable(&held) {
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
                // CloudKit asked to wait before this record is asked for again.
                View::Stored(_) | View::Missing if self.waiting.contains(&held.key) => {}
                View::Stored(_) | View::Missing => recovery.names.extend(name_of(&held.key)),
            }
        }
        Ok(recovery)
    }
}
