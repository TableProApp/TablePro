// Each record's answer to a modify call (0054, The CloudKit transport): a save that landed takes its new system fields
// as its base, a deletion that landed or found nothing drops its base, and every other answer leaves the base as it
// was, so the diff finds the change again.

use std::collections::{BTreeSet, HashMap};

use super::{Answers, Item, Op, PushReport, Pusher, Waits};
use crate::adapters::approval;
use crate::api::cloudkit::{CloudKitFailure, CloudKitOutcome};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, RecordKey};
use crate::api::state::{BaseRow, Row, RowKey};
use crate::cloudkit::codes::{Failure, failure};
use crate::cloudkit::fetch::ServerChanged;

// Which of two stops a pass reports: what explains the others, the app and the account before the zone, the zone
// before storage, as the Swift engine ranked them.
const fn severity(failure: &CloudKitFailure) -> u8 {
    match failure {
        CloudKitFailure::Other { .. } => 6,
        CloudKitFailure::Restricted => 5,
        CloudKitFailure::NoAccount => 4,
        CloudKitFailure::AccountTemporarilyUnavailable => 3,
        CloudKitFailure::ZoneNotFound | CloudKitFailure::ZoneDeletedByUser => 2,
        _ => 1,
    }
}

fn saved(key: RecordKey, base: Option<&BaseRow>, system_fields: Vec<u8>, fields: serde_json::Value) -> BaseRow {
    BaseRow {
        key,
        tag: ChangeTag::CloudKit(system_fields),
        version: None,
        revision: None,
        epoch: None,
        deleted: None,
        fields: Some(fields),
        // A save keeps the record's creation date; a create learns its own from the next fetch.
        created_ms: base.and_then(|base| base.created_ms),
    }
}

impl Pusher<'_> {
    // Commits what one call's answers settle and returns the failure that stops the upload, if one did. An answer for
    // a name the call did not send, or of the other kind, settles nothing.
    pub(super) async fn answered(
        &self,
        call: Vec<Item>,
        outcomes: Vec<CloudKitOutcome>,
        answers: &mut Answers,
        report: &mut PushReport,
        waits: &mut Waits,
        failed: &mut BTreeSet<RecordKey>,
    ) -> Result<Option<CloudKitFailure>, SyncError> {
        let mut asked: HashMap<String, Item> = call.into_iter().map(|item| (item.name().to_owned(), item)).collect();
        let mut txn = self.fetcher.state.begin().await?;
        let mut stop: Option<CloudKitFailure> = None;
        for outcome in outcomes {
            let Some(Item { key, base, op }) = asked.remove(outcome.name()) else {
                continue;
            };
            match (op, outcome) {
                // A save always lands on new system fields; one with none is no answer this engine can settle.
                (Op::Save { fields, .. }, CloudKitOutcome::Saved { system_fields, .. })
                    if !system_fields.is_empty() =>
                {
                    txn.put(Row::Base(saved(key, base.as_ref(), system_fields, fields)))
                        .await?;
                    report.saved = report.saved.saturating_add(1);
                }
                // A deletion that found no record is done as well. A record the person deleted here has nothing left
                // to approve.
                (Op::Delete { .. }, CloudKitOutcome::Deleted { .. } | CloudKitOutcome::UnknownItem { .. }) => {
                    for row in approval::rows_of(txn.as_mut(), &key).await? {
                        txn.delete(&RowKey::Approval(row.key, row.field)).await?;
                    }
                    txn.delete(&RowKey::Base(key)).await?;
                    report.deleted = report.deleted.saturating_add(1);
                }
                // A deletion carries no change tag, so CloudKit never refuses one as changed.
                (Op::Save { .. }, CloudKitOutcome::ServerChanged { name, server }) => {
                    answers.keys.insert(name.clone(), key);
                    answers.conflicts.push(ServerChanged { name, server });
                }
                (Op::Save { .. }, CloudKitOutcome::UnknownItem { name }) => {
                    answers.keys.insert(name.clone(), key);
                    answers.lost.push(name);
                }
                (
                    _,
                    CloudKitOutcome::Failed {
                        code, retry_after_ms, ..
                    },
                ) => {
                    if let Some(wait) = retry_after_ms {
                        waits.hold(key.clone(), self.now_ms, wait);
                        report.wait(Some(wait));
                    }
                    failed.insert(key.clone());
                    match failure(code) {
                        Failure::Stops(failure) => {
                            if stop.as_ref().is_none_or(|held| severity(&failure) > severity(held)) {
                                stop = Some(failure);
                            }
                            report.failed.push((key, Some(code)));
                        }
                        Failure::Later => {
                            report.wait(None);
                            report.failed.push((key, Some(code)));
                        }
                        Failure::TooLarge => report.refuse(key, CloudKitFailure::LimitExceeded.code()),
                        Failure::Retry => report.failed.push((key, Some(code))),
                    }
                }
                (_, _) => {
                    failed.insert(key.clone());
                    report.failed.push((key, None));
                }
            }
        }
        for Item { key, .. } in asked.into_values() {
            failed.insert(key.clone());
            report.failed.push((key, None));
        }
        self.stop.check()?;
        txn.commit().await?;
        Ok(stop)
    }
}
