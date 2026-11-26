// The modify half of the CloudKit engine (0054, A push; Rules for both providers). What a store holds that differs
// from its bases goes up in batches split by count and bytes, and again in halves on `limitExceeded`; each record's
// outcome settles its base, in one commit per call. A save refused with `serverRecordChanged` merges onto the server's
// copy and goes up again on its tag. A save answered `unknownItem` meets the deletion rules, so a content edit comes
// back as a create and a placement-only edit is dropped (D12). A record CloudKit asks to wait is not sent before then.

mod batch;
mod outcome;
mod pass;
mod zone;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{CloudValue, RecordType, from_wire, record_name, record_type_of};
use tablepro_records::record_id::shortened;

pub use pass::{CloudKitParts, CloudKitReport, CloudKitSync};

use super::codes;
use super::fetch::{Categories, Fetcher, PROFILES, SCOPE, ServerChanged, carried};
use crate::adapters::fields::{get, set};
use crate::adapters::{approval, unsettled};
use crate::api::adapter::{LocalRecord, LocalRecords};
use crate::api::cloudkit::{CloudKitFailure, CloudKitField, CloudKitRecord, CloudKitValue};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, KindName, RecordKey};
use crate::api::state::{BaseRow, Row, RowRange, Standing, Table};
use crate::engine::{Backoff, JournalIds, Pending, PendingOp, StopSignal, diff};

// A pass sends again what a refusal merged, at most this many times; what is left waits for the next pass.
const ROUNDS: usize = 3;

// Records CloudKit asked to wait, until when, in milliseconds since the Unix epoch. Kept for the engine's session, so a
// pass the person or a CloudKit push starts early still does not send or ask for them. A wait past the scheduler's cap
// is read as the cap, so CloudKit cannot hold a record off until a restart.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Waits(BTreeMap<RecordKey, i64>);

impl Waits {
    pub fn hold(&mut self, key: RecordKey, now_ms: i64, wait_ms: u64) {
        let wait = i64::try_from(wait_ms.min(Backoff::MAX_RETRY_AFTER_MS)).unwrap_or(i64::MAX);
        let until_ms = now_ms.saturating_add(wait);
        let until = self.0.entry(key).or_insert(until_ms);
        *until = (*until).max(until_ms);
    }

    pub fn holds(&self, key: &RecordKey, now_ms: i64) -> bool {
        self.0.get(key).is_some_and(|until| *until > now_ms)
    }

    // How long until the first wait still running ends.
    pub fn next_in(&self, now_ms: i64) -> Option<u64> {
        self.0
            .values()
            .filter(|until| **until > now_ms)
            .map(|until| u64::try_from(until.saturating_sub(now_ms)).unwrap_or(u64::MAX))
            .min()
    }

    // Every record still waiting.
    pub fn keys(&self, now_ms: i64) -> BTreeSet<RecordKey> {
        self.0
            .iter()
            .filter(|(_, until)| **until > now_ms)
            .map(|(key, _)| key.clone())
            .collect()
    }

    fn prune(&mut self, now_ms: i64) {
        self.0.retain(|_, until| *until > now_ms);
    }

    fn waiting<'w>(&'w self, kind: &'w KindName, now_ms: i64) -> impl Iterator<Item = String> + 'w {
        self.0
            .iter()
            .filter(move |(key, until)| key.kind == *kind && **until > now_ms)
            .map(|(key, _)| key.record_id.clone())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PushReport {
    // What the diff found to send, on the first round.
    pub queued: usize,
    pub saved: u32,
    pub deleted: u32,
    // Saves refused with `serverRecordChanged` and merged onto the server's copy.
    pub merged: u32,
    // Saves answered `unknownItem`, settled by the deletion rules.
    pub lost: u32,
    pub calls: u32,
    // Left for a later pass, with CloudKit's code; None when it gave no answer for the record or its copy did not read.
    pub failed: Vec<(RecordKey, Option<i64>)>,
    // Kept on the device with a notice, with the code: too large for CloudKit, or a value the projection cannot write.
    pub refused: BTreeMap<RecordKey, String>,
    // CloudKit throttled a record. The next pass waits at least `retry_after_ms`, or backs off when it named none.
    pub throttled: bool,
    pub retry_after_ms: Option<u64>,
}

impl PushReport {
    fn refuse(&mut self, key: RecordKey, code: &str) {
        self.refused.entry(key).or_insert_with(|| code.to_owned());
    }

    fn wait(&mut self, retry_after_ms: Option<u64>) {
        self.throttled = true;
        let capped = retry_after_ms.map(|wait| wait.min(Backoff::MAX_RETRY_AFTER_MS));
        self.retry_after_ms = self.retry_after_ms.max(capped);
    }
}

#[derive(Debug, Clone)]
enum Op {
    // `fields` is what iCloud carries of the copy, which the base takes once the save lands.
    Save { record: CloudKitRecord, fields: Value },
    Delete { name: String },
}

#[derive(Debug, Clone)]
struct Item {
    key: RecordKey,
    base: Option<BaseRow>,
    op: Op,
}

impl Item {
    fn name(&self) -> &str {
        match &self.op {
            Op::Save { record, .. } => &record.name,
            Op::Delete { name } => name,
        }
    }
}

// What one round's answers leave to settle, by the names CloudKit answered with.
#[derive(Debug, Default)]
struct Answers {
    conflicts: Vec<ServerChanged>,
    lost: Vec<String>,
    keys: HashMap<String, RecordKey>,
}

// What a round leaves out of its diff.
struct Leave<'a> {
    // Records this pass sent that failed, or a refused copy: the next pass tries them again.
    failed: &'a BTreeSet<RecordKey>,
    waits: &'a Waits,
    // A journal pass diffs only the records the journal named (0060).
    named: Option<&'a JournalIds>,
    // A later round sends only what the earlier one merged.
    only: Option<&'a BTreeSet<RecordKey>>,
}

fn cloudkit_value(value: CloudValue) -> CloudKitValue {
    match value {
        CloudValue::Text(text) => CloudKitValue::Text(text),
        CloudValue::Int64(number) => CloudKitValue::Int64(number),
        CloudValue::Double(number) => CloudKitValue::Double(number),
        CloudValue::Timestamp(millis) => CloudKitValue::Timestamp(millis),
        CloudValue::Bytes(bytes) => CloudKitValue::Bytes(bytes),
        CloudValue::TextList(items) => CloudKitValue::TextList(items),
    }
}

// A copy the projection cannot write, by the projection's own code.
fn unwritable(kind: Kind, record: &LocalRecord) -> &'static str {
    match from_wire(kind, &record.record_id, &record.fields, 0) {
        Err(error) => error.code(),
        Ok(_) => "records.bad_field",
    }
}

// The diff's copy and the save's both take the base's value in each member the approval queue holds.
fn at_base(
    kind: &KindName,
    waiting: &BTreeMap<(KindName, String), BTreeSet<String>>,
    bases: &[BaseRow],
    local: &mut LocalRecords,
    kept: &mut BTreeMap<String, LocalRecord>,
) {
    for base in bases {
        let id = &base.key.record_id;
        let Some(members) = waiting.get(&(kind.clone(), id.clone())) else {
            continue;
        };
        let copies = local
            .records
            .iter_mut()
            .filter(|record| record.record_id == *id)
            .chain(kept.get_mut(id));
        for copy in copies {
            for pointer in members {
                set(&mut copy.fields, pointer, get(base.fields.as_ref(), pointer).cloned());
            }
        }
    }
}

// Both copies also take the base's value where the store's copy leaves it unsaid: a copy an earlier build wrote then
// sends nothing over the value another device holds.
fn unsettled_at_base(
    kind: Kind,
    bases: &[BaseRow],
    local: &mut LocalRecords,
    kept: &mut BTreeMap<String, LocalRecord>,
) {
    for base in bases {
        let id = &base.key.record_id;
        let Some(stored) = kept.get(id) else {
            continue;
        };
        let pointers = unsettled::reading(kind, &stored.fields, base.fields.as_ref());
        if pointers.is_empty() {
            continue;
        }
        let copies = local
            .records
            .iter_mut()
            .filter(|record| record.record_id == *id)
            .chain(kept.get_mut(id));
        for copy in copies {
            for pointer in &pointers {
                set(&mut copy.fields, pointer, get(base.fields.as_ref(), pointer).cloned());
            }
        }
    }
}

pub struct Pusher<'p> {
    fetcher: &'p Fetcher<'p>,
    stop: &'p StopSignal,
    now_ms: i64,
    // The categories as the person sets them while the push runs; the fetcher's otherwise.
    live: Option<&'p Mutex<Categories>>,
}

impl<'p> Pusher<'p> {
    pub const fn new(fetcher: &'p Fetcher<'p>, stop: &'p StopSignal, now_ms: i64) -> Self {
        Self {
            fetcher,
            stop,
            now_ms,
            live: None,
        }
    }

    // A category turned off while the push runs sends nothing more from its next call on.
    #[must_use]
    pub const fn following(mut self, categories: &'p Mutex<Categories>) -> Self {
        self.live = Some(categories);
        self
    }

    // The live categories only narrow what the fetch read: a kind turned on mid-pass waits for the full read the next
    // pass makes, since its bases are stale until then.
    fn syncs(&self, kind: Kind) -> bool {
        self.fetcher.categories.syncs(kind)
            && self
                .live
                .is_none_or(|live| live.lock().unwrap_or_else(PoisonError::into_inner).syncs(kind))
    }

    pub async fn push(&self, waits: &mut Waits, named: Option<&JournalIds>) -> Result<PushReport, SyncError> {
        self.fetcher.settle_pending().await?;
        waits.prune(self.now_ms);
        let mut report = PushReport::default();
        let mut failed = BTreeSet::new();
        let mut only: Option<BTreeSet<RecordKey>> = None;
        for round in 0..ROUNDS {
            let leave = Leave {
                failed: &failed,
                waits,
                named,
                only: only.as_ref(),
            };
            let items = self.pending(&mut report, &leave).await?;
            if round == 0 {
                report.queued = items.len();
            }
            if items.is_empty() {
                break;
            }
            let mut answers = Answers::default();
            self.send(items, &mut answers, &mut report, waits, &mut failed).await?;
            if answers.conflicts.is_empty() && answers.lost.is_empty() {
                break;
            }
            only = Some(self.settle(answers, &mut report, waits, &mut failed).await?);
        }
        Ok(report)
    }

    // The refusals merged onto the server's copy and the lost saves settled by the deletion rules; what the next round
    // sends of them.
    async fn settle(
        &self,
        answers: Answers,
        report: &mut PushReport,
        waits: &mut Waits,
        failed: &mut BTreeSet<RecordKey>,
    ) -> Result<BTreeSet<RecordKey>, SyncError> {
        let Answers { conflicts, lost, keys } = answers;
        let key = |name: &str| keys.get(name).cloned();
        let mut again = BTreeSet::new();
        let mut gone = Vec::new();
        if !conflicts.is_empty() {
            let rebased = self.fetcher.rebase(conflicts).await?;
            report.merged = report
                .merged
                .saturating_add(u32::try_from(rebased.merged.len()).unwrap_or(u32::MAX));
            again.extend(rebased.merged.iter().filter_map(|name| key(name)));
            gone.extend(rebased.gone);
            for refusal in rebased.failed {
                let Some(held) = key(&refusal.name) else {
                    continue;
                };
                if let Some(wait) = refusal.retry_after_ms {
                    waits.hold(held.clone(), self.now_ms, wait);
                    report.wait(Some(wait));
                } else if refusal.code.is_some_and(codes::later) {
                    report.wait(None);
                }
                failed.insert(held.clone());
                report.failed.push((held, refusal.code));
            }
        }
        if !lost.is_empty() {
            let settled = self.fetcher.lost(lost).await?;
            report.lost = report
                .lost
                .saturating_add(u32::try_from(settled.gone.len()).unwrap_or(u32::MAX));
            gone.extend(settled.gone);
        }
        let (profiles, others): (Vec<RecordKey>, Vec<RecordKey>) = gone
            .iter()
            .filter_map(|name| key(name))
            .partition(|held| held.kind.known().is_some_and(|kind| PROFILES.contains(&kind)));
        again.extend(others);
        // A lost profile with no content edit keeps its base until its deletion comes through the changes, so this
        // pass does not send it again.
        let revived = self.fetcher.revive(&profiles).await?;
        for held in profiles {
            if revived.contains(&held) {
                again.insert(held);
            } else {
                failed.insert(held);
            }
        }
        Ok(again)
    }

    async fn held(&self) -> Result<BTreeSet<RecordKey>, SyncError> {
        let mut txn = self.fetcher.state.begin().await?;
        let rows = txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(held) => Some(held.key),
                _ => None,
            })
            .collect())
    }

    async fn bases(&self, kind: Kind) -> Result<Vec<BaseRow>, SyncError> {
        let mut txn = self.fetcher.state.begin().await?;
        let rows = txn
            .scan(&RowRange::ScopeKind(Table::Bases, SCOPE, KindName::of(kind)))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Base(base) => Some(base),
                _ => None,
            })
            .collect())
    }

    // Each kind's store against its bases, in what iCloud carries of each copy. A kind whose category is off sends
    // nothing; Local only copies, held records and those this pass leaves out stay. A member waiting for the person, or
    // kept here after a rejection, goes up at its base's value, so the device never sends its old value back over the
    // pulled one (0054, Rules for both providers).
    async fn pending(&self, report: &mut PushReport, leave: &Leave<'_>) -> Result<Vec<Item>, SyncError> {
        let held = self.held().await?;
        let waiting = approval::held_members(self.fetcher.state.begin().await?.as_mut(), SCOPE).await?;
        let mut items = Vec::new();
        for (kind, adapter) in &self.fetcher.adapters {
            let kind = *kind;
            if !self.syncs(kind) {
                continue;
            }
            let Some(record_type) = record_type_of(kind).filter(|record_type| record_type.deployed) else {
                continue;
            };
            let name = KindName::of(kind);
            if leave.only.is_some_and(|only| only.iter().all(|key| key.kind != name)) {
                continue;
            }
            let named: Option<HashSet<String>> = match leave.named {
                Some(named) => match named.get(&kind) {
                    Some(ids) => Some(ids.iter().map(|id| shortened(kind, id.clone())).collect()),
                    None => continue,
                },
                None => None,
            };
            let stored = adapter.records(SCOPE).await?;
            let (mut local, mut kept, unwritten) = Self::carried_copies(kind, stored);
            let bases = self.bases(kind).await?;
            at_base(&name, &waiting, &bases, &mut local, &mut kept);
            unsettled_at_base(kind, &bases, &mut local, &mut kept);
            let skip: HashSet<String> = held
                .iter()
                .chain(leave.failed)
                .filter(|key| key.kind == name)
                .map(|key| key.record_id.clone())
                .chain(unwritten.iter().map(|(id, _)| id.clone()))
                .chain(leave.waits.waiting(&name, self.now_ms))
                .collect();
            for (id, code) in unwritten {
                report.refuse(RecordKey::new(SCOPE, kind, id), code);
            }
            let diffed = diff(SCOPE, kind, &local, &bases, &skip);
            for (key, code) in diffed.refused {
                report.refuse(key, code);
            }
            for pending in diffed.pending {
                let sent = leave.only.is_none_or(|only| only.contains(&pending.key))
                    && named
                        .as_ref()
                        .is_none_or(|named| named.contains(&pending.key.record_id));
                if !sent {
                    continue;
                }
                match self.item(kind, record_type, pending, &kept) {
                    Ok(item) => items.push(item),
                    Err((key, code)) => report.refuse(key, code),
                }
            }
        }
        Ok(items)
    }

    // The store's copies by the id the zone names them with (0052, Long ids), each as what iCloud carries of it, so a
    // field the zone never holds reads as no edit. A copy the projection cannot take stays in the set, so its base
    // does not read as a deletion, and is left out with its code.
    fn carried_copies(
        kind: Kind,
        stored: LocalRecords,
    ) -> (LocalRecords, BTreeMap<String, LocalRecord>, Vec<(String, &'static str)>) {
        let mut kept: BTreeMap<String, LocalRecord> = BTreeMap::new();
        for record in stored.records {
            let wire = shortened(kind, record.record_id.clone());
            // Two copies under one name: the one kept under the long id is the store's own.
            if kept.get(&wire).is_none_or(|held| held.record_id == wire) {
                kept.insert(wire, record);
            }
        }
        let mut unwritten = Vec::new();
        let records = kept
            .iter()
            .map(|(wire, record)| {
                let fields = carried(kind, wire, &record.fields).unwrap_or_else(|| {
                    if record.standing == Standing::Syncs {
                        unwritten.push((wire.clone(), unwritable(kind, record)));
                    }
                    record.fields.clone()
                });
                LocalRecord {
                    record_id: wire.clone(),
                    fields,
                    standing: record.standing,
                }
            })
            .collect();
        let local = LocalRecords {
            records,
            unreadable: stored.unreadable.into_iter().map(|id| shortened(kind, id)).collect(),
            tombstones: Vec::new(),
        };
        (local, kept, unwritten)
    }

    // A save sets every field Production holds for the type, on the system fields of its base, so the change tag
    // guards it; a create sends none.
    fn item(
        &self,
        kind: Kind,
        record_type: &RecordType,
        pending: Pending,
        kept: &BTreeMap<String, LocalRecord>,
    ) -> Result<Item, (RecordKey, &'static str)> {
        let Pending { key, base, op } = pending;
        let Some(name) = record_name(kind, &key.record_id) else {
            return Err((key, "records.bad_record_name"));
        };
        let op = match op {
            PendingOp::Delete => Op::Delete { name },
            PendingOp::Write { fields, .. } => {
                let Some(record) = kept.get(&key.record_id) else {
                    return Err((key, "records.bad_field"));
                };
                let saved = match from_wire(kind, &record.record_id, &record.fields, self.now_ms) {
                    Ok(Some(saved)) => saved,
                    Ok(None) => return Err((key, "records.unknown_record_type")),
                    Err(error) => return Err((key, error.code())),
                };
                let system_fields = base.as_ref().and_then(|base| match &base.tag {
                    ChangeTag::CloudKit(bytes) if !bytes.is_empty() => Some(bytes.clone()),
                    _ => None,
                });
                Op::Save {
                    record: CloudKitRecord {
                        record_type: record_type.name.to_owned(),
                        name,
                        system_fields,
                        created_ms: None,
                        fields: saved
                            .into_iter()
                            .map(|(name, value)| CloudKitField {
                                name: name.to_owned(),
                                value: value.map(cloudkit_value),
                            })
                            .collect(),
                    },
                    fields,
                }
            }
        };
        Ok(Item { key, base, op })
    }

    // One modify call per batch, a batch CloudKit finds too large sent again in halves, and each call's answers
    // committed before the next goes. A record too large alone is kept on the device.
    async fn send(
        &self,
        items: Vec<Item>,
        answers: &mut Answers,
        report: &mut PushReport,
        waits: &mut Waits,
        failed: &mut BTreeSet<RecordKey>,
    ) -> Result<(), SyncError> {
        let mut calls = batch::calls(items);
        calls.reverse();
        while let Some(call) = calls.pop() {
            self.stop.check()?;
            let call: Vec<Item> = call
                .into_iter()
                .filter(|item| item.key.kind.known().is_some_and(|kind| self.syncs(kind)))
                .collect();
            if call.is_empty() {
                continue;
            }
            let mut saves = Vec::new();
            let mut deletes = Vec::new();
            for item in &call {
                match &item.op {
                    Op::Save { record, .. } => saves.push(record.clone()),
                    Op::Delete { name } => deletes.push(name.clone()),
                }
            }
            report.calls = report.calls.saturating_add(1);
            let account = self.fetcher.account.clone();
            match self.fetcher.transport.modify(account, saves, deletes).await {
                Ok(outcomes) => {
                    if let Some(stop) = self.answered(call, outcomes, answers, report, waits, failed).await? {
                        return Err(stop.into());
                    }
                }
                Err(CloudKitFailure::LimitExceeded) if call.len() > 1 => {
                    let (first, second) = batch::halves(call);
                    calls.push(second);
                    calls.push(first);
                }
                Err(failure @ CloudKitFailure::LimitExceeded) => {
                    for item in call {
                        failed.insert(item.key.clone());
                        report.refuse(item.key, failure.code());
                    }
                }
                Err(failure) => return Err(failure.into()),
            }
        }
        Ok(())
    }
}
