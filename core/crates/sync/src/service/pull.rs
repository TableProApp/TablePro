// A scope's pull (0051, Pull; 0054, A pass): pages from the cursor, each written to the stores, then the bases, then
// the cursor with the key version in force at it, so a crash replays a page with no effect. A snapshot's key objects
// and envelopes wait until it is caught up; it commits its cursor only then.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use tablepro_keys::encoding::Version;
use tablepro_records::Kind;
use tablepro_records::move_marker::{self, MoveMarker};
use tablepro_records::schema::readable;

use super::keys::{Family, HistoryOpens, KeyMark, Opens, family, key_mark};
use super::refill::Cut;
use super::scopes::refresh;
use super::{PassCtx, ServiceSync, begin};
use crate::adapters::approval::{self, Split};
use crate::adapters::categories::DeviceCategories;
use crate::adapters::{apply_keeping, conflict, local_view, unsettled};
use crate::api::adapter::{LocalChange, LocalRecord, RecordAdapter};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey, ScopeName};
use crate::api::key_flows::{ArrivalOrder, CaughtUp};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{
    ApprovalDecision, ApprovalRow, BaseRow, ConflictRow, DeferredRow, DeletedHistoryRow, HeldReason, HeldRow, Row,
    RowKey, RowRange, ScopeRow, Standing, Table,
};
use crate::api::transport::{DeletedReason, Proof, PullRequest, PulledPage, PulledRecord, TransportError};
use crate::engine::{Judgement, base_of, settle, settle_moved};
use crate::moves::Arrival;

struct Pull {
    scope: ScopeName,
    snapshot: bool,
    // A new epoch: each base is judged against the cut that ended its history.
    cut: Option<Cut>,
    // Kinds whose store was restored, replaced or never seen: the pull wins.
    pull_wins: HashSet<Kind>,
    // Records a refill's store refused: the pull wins on whatever page brings them, as the refill would have.
    held_refills: HashSet<RecordKey>,
    cursor: Option<Cursor>,
    older_cursor: Option<Cursor>,
    in_force: Option<Version>,
    held_keys: Vec<PulledRecord>,
    held_envelopes: Vec<PulledRecord>,
    seen: HashSet<(String, String)>,
    // A locked or unapproved device holds no key to check an envelope with: it keeps each one until it can.
    can_open: bool,
    // The bytes of key objects and envelopes a snapshot keeps until it is caught up.
    buffered: usize,
    // The kinds this build reads in the scope, which the row keeps once a snapshot read them all.
    reading: Vec<KindName>,
    // An envelope in order waited for the keys: a snapshot reads it again on the next pass.
    new_waits: bool,
    // History entries a snapshot still takes, newest first, before it follows the changes; None takes them all.
    window: Option<usize>,
    // A history snapshot still reads older pages, and has left them, so `older_cursor` is where paging back starts.
    older: bool,
    older_read: bool,
    // The categories as the pass began, so one pass never reads a kind it then skips.
    categories: DeviceCategories,
    // Personal data arriving this pass, in the personal scope only.
    arrival: Option<Arc<Arrival>>,
    // The sealed copy of each history entry this pull opened, which a hold keeps instead of the plaintext.
    sealed: HashMap<RecordKey, PulledRecord>,
}

// A server that never lets a pull catch up, or a snapshot too large to keep, ends the pass instead of the device.
const MAX_PAGES: usize = 100_000;
const MAX_BUFFERED: usize = 256 << 20;

fn buffered_bytes(record: &PulledRecord) -> usize {
    record.fields_json.as_ref().map_or(0, String::len) + record.record_id.len() + 128
}

impl Pull {
    // A snapshot's key objects and envelopes wait until it is caught up.
    fn keep(&mut self, record: PulledRecord) -> Result<(), SyncError> {
        self.buffered += buffered_bytes(&record);
        if self.buffered > MAX_BUFFERED {
            return Err(SyncError::Malformed {
                what: "snapshot larger than a device keeps",
            });
        }
        if family(self.scope, &record.kind).is_some() {
            self.held_keys.push(record);
        } else {
            self.held_envelopes.push(record);
        }
        Ok(())
    }

    fn judge(&self, kind: Kind, key: &RecordKey, base: Option<&BaseRow>, record: &PulledRecord) -> Judgement {
        if self.pull_wins.contains(&kind) || self.held_refills.contains(key) {
            return Judgement::PullWins;
        }
        match (&self.cut, base) {
            (Some(cut), Some(base)) if base.tag != record.tag && cut.lost(base) && !cut.written_after(base, record) => {
                Judgement::LocalWins
            }
            _ => Judgement::Merge,
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct PageWrites {
    // Each store change with the pulled record it settles, which is held if the store refuses it.
    store: Vec<(usize, PulledRecord, LocalChange)>,
    bases: Vec<BaseRow>,
    dropped: Vec<RecordKey>,
    held: Vec<HeldRow>,
    unheld: Vec<RecordKey>,
    conflicts: Vec<ConflictRow>,
    // Open conflicts a pull settled.
    resolved: Vec<RecordKey>,
    approvals: Vec<(RecordKey, Split)>,
    deferred: Vec<DeferredRow>,
    undeferred: Vec<RecordKey>,
    // Rows of other tables that settle in the same commit.
    rows: Vec<Row>,
    // Records the store refused to keep, held by id with the server's copy.
    pub(super) refused: Vec<RecordKey>,
    // The refills this commit ends, as their `stores_kinds` marks.
    refilled: Vec<RowKey>,
}

impl PageWrites {
    fn is_empty(&self) -> bool {
        self.store.is_empty()
            && self.bases.is_empty()
            && self.dropped.is_empty()
            && self.held.is_empty()
            && self.unheld.is_empty()
            && self.conflicts.is_empty()
            && self.resolved.is_empty()
            && self.approvals.is_empty()
            && self.deferred.is_empty()
            && self.undeferred.is_empty()
            && self.rows.is_empty()
            && self.refilled.is_empty()
    }

    // The store refused the record's value: it is held by id with the server's copy, as a record this build cannot
    // read is, and nothing the pull settled for it lands, so its base stays the copy the store holds (0054, Rules for
    // both providers).
    fn refuse(&mut self, key: RecordKey, record: PulledRecord, refilling: bool) {
        self.bases.retain(|base| base.key != key);
        self.dropped.retain(|dropped| *dropped != key);
        self.unheld.retain(|unheld| *unheld != key);
        self.resolved.retain(|resolved| *resolved != key);
        self.approvals.retain(|(approved, _)| *approved != key);
        self.undeferred.retain(|undeferred| *undeferred != key);
        self.held.retain(|held| held.key != key);
        // A history entry is held sealed. One whose sealed copy is gone keeps only its id, so no plaintext rests in the
        // state file, and the server serves the sealed copy again.
        let record = if key.kind.known() == Some(Kind::HistoryEntry) && record.fields_json.is_none() {
            PulledRecord {
                fields: None,
                fields_json: None,
                ..record
            }
        } else {
            record
        };
        let reason = if refilling {
            HeldReason::RefusedInRefill
        } else {
            HeldReason::Unreadable
        };
        self.held.push(held(reason, key.clone(), record));
        self.refused.push(key);
    }
}

#[derive(Debug, Default)]
struct SettleInputs {
    bases: HashMap<RecordKey, BaseRow>,
    conflicts: HashMap<RecordKey, ConflictRow>,
    approvals: HashMap<RecordKey, Vec<ApprovalRow>>,
    // Records held whole until the person decides.
    awaiting: HashSet<RecordKey>,
    // The store's copies a refill found while their kind was off, which the kind merges against once it is read.
    deferred: HashMap<RecordKey, PulledRecord>,
    deleted_history: HashSet<String>,
}

// Every row of a record the provider deleted goes.
fn cleared(rows: &[ApprovalRow]) -> Split {
    Split {
        clear: rows.iter().map(|row| row.field.clone()).collect(),
        ..Split::default()
    }
}

struct LocalIndex {
    records: HashMap<String, LocalRecord>,
    unreadable: HashSet<String>,
}

fn held(reason: HeldReason, key: RecordKey, record: PulledRecord) -> HeldRow {
    HeldRow { key, reason, record }
}

impl ServiceSync {
    // Read for each call, since an approval or a recovery in this pass changes which DSK proves (0051, DPoP).
    async fn scope_proof(&self, scope: ScopeName) -> Result<Proof, SyncError> {
        Ok(match scope {
            ScopeName::Team(_) => Proof::None,
            ScopeName::Personal | ScopeName::History => self.keys.dpop_key().await?.map_or(Proof::None, Proof::Dpop),
        })
    }

    pub(super) async fn pull_scope(
        &self,
        ctx: &mut PassCtx,
        waited: &mut HashMap<ScopeName, KeyMark>,
        info: &ScopeInfo,
    ) -> Result<(), SyncError> {
        let scope = info.scope;
        let adapters = self.adapters.in_scope(scope);
        let stored = self.scope_row(scope).await?;
        let mut row = stored.clone().unwrap_or_else(|| ScopeRow::new(scope));
        if row.epoch.is_some_and(|held| held != ctx.body.epoch) {
            row.refill = true;
        }
        ctx.new_epoch |= row.refill;
        let arrival = ctx.arrival.clone().filter(|_| scope == ScopeName::Personal);
        // A first upload from no provider refills the kinds only the personal scope holds, by the marks it wrote: the
        // server's copy wins, and what the server lacks goes up as a create. A move from iCloud merges against the copy
        // both providers last shared instead, whatever the service file saw of the stores. The kinds whose category is
        // on take the refill they owe. One that is off is read only by the pass that marked its store, for the copies the store
        // holds then, which it merges against once it is on; a later refill of others never takes them again. It keeps
        // its mark (0066, Per-kind refills; `deferred`).
        let categories = ctx.categories_in(scope);
        let moving = arrival.as_deref().is_some_and(Arrival::meets_its_own_bases);
        let pull_wins: HashSet<Kind> = adapters
            .iter()
            .filter(|adapter| {
                !moving
                    && ctx.owes(adapter.store(), adapter.kind())
                    && (categories.syncs(adapter.kind()) || ctx.marked(adapter.store()))
            })
            .map(|adapter| adapter.kind())
            .collect();
        let can_open = ctx.keys_ready;
        let rebuilding = self.keys.rebuilding();
        let sealed = match scope {
            ScopeName::History => Kind::HistoryEntry,
            ScopeName::Personal | ScopeName::Team(_) => Kind::SecretEnvelope,
        };
        // Envelopes kept while the device could not check them are read again in a snapshot once it can, which
        // serves each one's current copy after the key objects (0051, Pull). Once a snapshot judged them, only a change
        // of the keys reads them again, so one under a key this account was never given refills nothing. While their
        // kind is off nothing reads them, and turning it on reads them again.
        let waiting = can_open
            && categories.syncs(sealed)
            && self.holds_scope_key(scope).await?
            && !self.waiting_envelopes(scope).await?.is_empty()
            && waited.get(&scope) != Some(&key_mark(&self.state, scope, can_open, rebuilding).await?);
        // A build that reads a kind the last pull did not fetches again what it held for it (0054, Rules).
        // A kind this device turned off is not read, so turning it on reads it again the same way.
        let mut reading: Vec<KindName> = adapters
            .iter()
            .map(|adapter| adapter.kind())
            .filter(|kind| categories.syncs(*kind))
            .map(KindName::of)
            .collect();
        reading.sort();
        let reads_more = reading.iter().any(|kind| !row.read_kinds.contains(kind));
        let snapshot = row.cursor.is_none() || row.refill || !pull_wins.is_empty() || waiting || reads_more;
        let mut pull = Pull {
            scope,
            snapshot,
            cut: row.refill.then(|| Cut::new(&row.lineage, &info.epochs)),
            pull_wins,
            held_refills: self.held_refills(scope).await?,
            cursor: if snapshot { None } else { row.cursor.clone() },
            older_cursor: None,
            in_force: if snapshot { None } else { row.key_version },
            held_keys: Vec::new(),
            held_envelopes: Vec::new(),
            seen: HashSet::new(),
            can_open,
            buffered: 0,
            reading,
            new_waits: false,
            window: (scope == ScopeName::History && snapshot)
                .then(|| self.history_window().map(|entries| entries as usize))
                .flatten(),
            older: scope == ScopeName::History && snapshot,
            older_read: false,
            categories,
            arrival,
            sealed: HashMap::new(),
        };
        refresh(&mut row, info);
        if row.epoch.is_none() {
            row.epoch = Some(ctx.body.epoch);
            row.lineage.clone_from(&info.epochs);
        }
        // A refill is kept before the first page, so a crash goes on refilling.
        if stored.as_ref() != Some(&row) {
            self.commit_page(PageWrites::default(), Some(&row)).await?;
        }
        if !pull.snapshot {
            self.retry_held(ctx, &mut pull, &adapters).await?;
        }
        let caught_up = self.pull_pages(ctx, &mut pull, &adapters, &mut row).await?;
        if pull.snapshot {
            self.finish_snapshot(ctx, &mut pull, &adapters, &mut row, info).await?;
            if self.waiting_envelopes(scope).await?.is_empty() {
                waited.remove(&scope);
            } else {
                waited.insert(scope, key_mark(&self.state, scope, can_open, rebuilding).await?);
            }
        } else if pull.new_waits {
            waited.remove(&scope);
        }
        self.read_roster(info, caught_up).await;
        Ok(())
    }

    async fn pull_pages(
        &self,
        ctx: &mut PassCtx,
        pull: &mut Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        row: &mut ScopeRow,
    ) -> Result<Option<CaughtUp>, SyncError> {
        for _ in 0..MAX_PAGES {
            self.check_stop()?;
            // A history snapshot asks for no more than its window still takes.
            let limit = pull
                .window
                .filter(|_| pull.older)
                .map(|left| u32::try_from(left.max(1)).unwrap_or(u32::MAX));
            let request = PullRequest {
                scope: pull.scope,
                cursor: pull.cursor.clone(),
                limit,
                proof: self.scope_proof(pull.scope).await?,
            };
            let page = match self.transport.pull(request).await {
                // The next pull takes a snapshot; the caller reads the scopes body first (0051, `cursor_expired`).
                Err(TransportError::CursorExpired) => {
                    row.cursor = None;
                    self.commit_page(PageWrites::default(), Some(row)).await?;
                    return Err(TransportError::CursorExpired.into());
                }
                other => other?,
            };
            let caught_up = page.caught_up || page.records.is_empty();
            // Only an empty page that says so lets the roster read before this pull be decided on (0051, `members`).
            let roster_ready = CaughtUp::from_page(pull.scope, &page);
            let next = next_cursor(pull, &page);
            if !caught_up && (next.is_none() || next == pull.cursor) {
                return Err(SyncError::Malformed {
                    what: "pull page that does not move its cursor",
                });
            }
            ctx.report.pulled += page.records.len();
            let writes = self.take_page(pull, adapters, page.records).await?;
            ctx.report.store_refused.extend(writes.refused.iter().cloned());
            pull.cursor = next;
            if pull.snapshot {
                if !writes.is_empty() {
                    self.commit_page(writes, None).await?;
                }
            } else {
                let before = row.clone();
                row.cursor.clone_from(&pull.cursor);
                row.key_version = pull.in_force;
                row.caught_up = caught_up;
                row.read_kinds.retain(|kind| pull.reading.contains(kind));
                // An idle pass commits nothing, so it writes no anchor.
                if !writes.is_empty() || *row != before {
                    self.commit_page(writes, Some(row)).await?;
                }
            }
            if caught_up {
                return Ok(roster_ready);
            }
        }
        Err(SyncError::Malformed {
            what: "pull that never catches up",
        })
    }

    // Records held because their store refused the value or its copy did not read go through the pull again from the
    // copy each row keeps, so a store or a build that now takes them does, with no change on the server and after a
    // restart too (0054, Rules for both providers). The rows are the newest copy the server served, and their bases
    // never moved past what the store holds. A record held again as it was writes nothing. A live envelope or history
    // entry is judged at its place in the server's order, which a row does not keep, so it waits for the server to
    // serve it again; their deletions need no key and go again like any other.
    async fn retry_held(
        &self,
        ctx: &mut PassCtx,
        pull: &mut Pull,
        adapters: &[Arc<dyn RecordAdapter>],
    ) -> Result<(), SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Held, pull.scope))
            .await?;
        let held: Vec<HeldRow> = rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(row)
                    if matches!(row.reason, HeldReason::Unreadable | HeldReason::RefusedInRefill)
                        && (row.record.fields_json.is_some()
                            || row.record.fields.is_some()
                            || row.record.deleted.is_some())
                        && row.record.kind.known().is_some_and(|kind| {
                            (row.record.deleted.is_some() || !matches!(kind, Kind::SecretEnvelope | Kind::HistoryEntry))
                                && adapters.iter().any(|adapter| adapter.kind() == kind)
                        }) =>
                {
                    Some(row)
                }
                _ => None,
            })
            .collect();
        if held.is_empty() {
            return Ok(());
        }
        // What a refill held takes the pull as the refill would have; the rest merges as any pull does.
        let (refilled, merged): (Vec<HeldRow>, Vec<HeldRow>) = held
            .into_iter()
            .partition(|row| row.reason == HeldReason::RefusedInRefill);
        for (batch, refill) in [(refilled, true), (merged, false)] {
            if batch.is_empty() {
                continue;
            }
            let wins = std::mem::take(&mut pull.pull_wins);
            if refill {
                pull.pull_wins = batch.iter().filter_map(|row| row.record.kind.known()).collect();
            }
            let records = batch.iter().map(|row| row.record.clone()).collect();
            let taken = self.take_page(pull, adapters, records).await;
            pull.pull_wins = wins;
            let mut writes = taken?;
            ctx.report.store_refused.extend(writes.refused.iter().cloned());
            writes.held.retain(|row| !batch.contains(row));
            writes.refused.clear();
            if !writes.is_empty() {
                self.commit_page(writes, None).await?;
            }
        }
        Ok(())
    }

    async fn held_refills(&self, scope: ScopeName) -> Result<HashSet<RecordKey>, SyncError> {
        Ok(begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Held, scope))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(held) if held.reason == HeldReason::RefusedInRefill => Some(held.key),
                _ => None,
            })
            .collect())
    }

    // A history entry settles in the clear once it opens; one that cannot open yet is held.
    async fn open_history_entry(
        &self,
        pull: &mut Pull,
        writes: &mut PageWrites,
        key: RecordKey,
        mut record: PulledRecord,
    ) -> Result<Option<PulledRecord>, SyncError> {
        if !pull.can_open {
            writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record));
            return Ok(None);
        }
        match self.history_opens(&record).await? {
            HistoryOpens::Plain(fields) => {
                pull.sealed.insert(key, record.clone());
                record.fields = Some(fields);
                record.fields_json = None;
                Ok(Some(record))
            }
            HistoryOpens::Refused => {
                writes.held.push(held(HeldReason::Unreadable, key, record));
                Ok(None)
            }
            HistoryOpens::Waits => {
                writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record));
                Ok(None)
            }
        }
    }

    // In revision order on a delta page: runs of key objects go to their flow, each envelope is checked under the
    // version in force at its place, and every other record settles against its base.
    async fn take_page(
        &self,
        pull: &mut Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        records: Vec<PulledRecord>,
    ) -> Result<PageWrites, SyncError> {
        let mut writes = PageWrites::default();
        let mut run: Option<(Family, Vec<PulledRecord>)> = None;
        let mut to_settle = Vec::new();
        for mut record in records {
            pull.seen
                .insert((record.kind.as_str().to_owned(), record.record_id.clone()));
            let key = RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone());
            // No store, base or patch ever holds a move marker; only an arriving move reads it (0051, Move markers).
            let marker = record.fields.as_mut().and_then(move_marker::strip);
            if let (Some(marker), Some(arrival)) = (marker, &pull.arrival) {
                arrival.marked(&key, marker);
            }
            // A kind this device turned off takes nothing of its store, so the snapshot that follows turning it on
            // settles what came meanwhile, deletions included (0054, Rules for both providers). Only a refill reads it
            // now, for what the refill decides that the store need not take yet.
            if let Some(kind) = record.kind.known().filter(|kind| !pull.categories.syncs(*kind)) {
                if pull.cut.is_some() || pull.pull_wins.contains(&kind) {
                    to_settle.push(record);
                }
                continue;
            }
            if record.kind.known().is_none() && !pull.categories.keeps_unknown(&record.kind) {
                continue;
            }
            // A live record always carries its fields; one without them is no deletion this device would sign.
            if record.deleted.is_none() && record.fields.is_none() {
                writes.held.push(held(HeldReason::Unreadable, key, record));
                continue;
            }
            // A copy without what a store needs to hold it is one this build cannot read: held by id, never applied,
            // so no pass reads its absence from the store as a deletion (0054, Rules for both providers).
            if let (Some(kind), Some(fields), None) = (record.kind.known(), record.fields.as_ref(), record.deleted)
                && !readable(kind, &record.record_id, fields)
            {
                writes.held.push(held(HeldReason::Unreadable, key, record));
                continue;
            }
            if let Some(next) = family(pull.scope, &record.kind) {
                // What the server holds now, which a push-back after a restore judges by (0051, After a restore).
                // With its fields, so a different record at the id never reads as this device's copy.
                writes.bases.push(base_of(&key, false, &record));
                if pull.snapshot {
                    pull.keep(record)?;
                } else {
                    match run.as_mut() {
                        Some((held, records)) if *held == next => records.push(record),
                        _ => {
                            self.flush_run(pull, run.take()).await?;
                            run = Some((next, vec![record]));
                        }
                    }
                }
                continue;
            }
            self.flush_run(pull, run.take()).await?;
            if record.kind.known() == Some(Kind::SecretEnvelope) {
                if pull.snapshot {
                    pull.keep(record)?;
                    continue;
                }
                if !pull.can_open {
                    writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record));
                    continue;
                }
                // In revision order an envelope is only ever checked under a version, never under a snapshot's rule.
                let opens = match pull.in_force {
                    Some(in_force) => self.envelope_opens(pull.scope, &record, Some(in_force)).await?,
                    None if record.deleted.is_some() => Opens::Taken,
                    None => Opens::Refused,
                };
                match opens {
                    Opens::Taken => {}
                    Opens::Refused => {
                        writes.held.push(held(HeldReason::Unreadable, key, record));
                        continue;
                    }
                    Opens::Waits => {
                        pull.new_waits = true;
                        writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record));
                        continue;
                    }
                }
            }
            if pull.scope == ScopeName::History
                && record.kind.known() == Some(Kind::HistoryEntry)
                && record.deleted.is_none()
            {
                if let Some(opened) = self.open_history_entry(pull, &mut writes, key, record).await? {
                    to_settle.push(opened);
                }
                continue;
            }
            to_settle.push(record);
        }
        self.flush_run(pull, run.take()).await?;
        self.settle_all(pull, adapters, to_settle, &mut writes).await?;
        Ok(writes)
    }

    async fn flush_run(&self, pull: &mut Pull, run: Option<(Family, Vec<PulledRecord>)>) -> Result<(), SyncError> {
        let Some((family, records)) = run else {
            return Ok(());
        };
        self.check_stop()?;
        // Each run starts from the position the page reached so far, which the state file holds only once the page
        // commits, so a second run of versions goes on from the first's; the position only moves forward (0056,
        // Rollback, In order).
        let applied = self
            .arrive(pull.scope, family, records, ArrivalOrder::InOrder, pull.in_force)
            .await?;
        pull.in_force = pull.in_force.max(applied.in_force);
        Ok(())
    }

    async fn settle_all(
        &self,
        pull: &Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        records: Vec<PulledRecord>,
        writes: &mut PageWrites,
    ) -> Result<(), SyncError> {
        if records.is_empty() {
            return Ok(());
        }
        let keys: Vec<RecordKey> = records
            .iter()
            .map(|record| RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone()))
            .collect();
        let inputs = self.settle_inputs(&keys).await?;
        let locals = local_indexes(pull.scope, adapters, &records).await?;
        for (key, record) in keys.into_iter().zip(records) {
            let adapter = record
                .kind
                .known()
                .and_then(|kind| adapters.iter().position(|adapter| adapter.kind() == kind));
            let (Some(kind), Some(index)) = (record.kind.known(), adapter) else {
                // A kind this build or this device does not sync is held by id and its base kept (0054, Rules).
                writes.bases.push(base_of(&key, false, &record));
                writes.held.push(held(HeldReason::UnknownKind, key, record));
                continue;
            };
            let local = locals.get(&index);
            if local.is_some_and(|local| local.unreadable.contains(&key.record_id)) {
                writes.held.push(held(HeldReason::Unreadable, key, record));
                continue;
            }
            // Arriving from iCloud, the record's first meet with the service is against the copy both providers last
            // shared: the move marker's, else this device's CloudKit base (0054, Moving between providers). Once a base
            // is committed, a later pull in the same move merges against it as any pull does.
            let stored_base = inputs.bases.get(&key);
            let arrival = pull.arrival.as_deref().filter(|_| stored_base.is_none());
            let moved = arrival.and_then(|arrival| arrival.icloud_base(&key));
            let marker = arrival.and_then(|arrival| arrival.marker(&key));
            let base = stored_base.or(moved.as_ref());
            let mut judgement = pull.judge(kind, &key, base, &record);
            // A copy a refill kept while the kind was off stands for the store the restore left: once the kind is on,
            // its refill merges against that copy, so what was edited since goes up (0066, `deferred`).
            let kept_copy = inputs
                .deferred
                .get(&key)
                .is_some_and(|deferred| deferred.fields.is_some());
            if judgement == Judgement::PullWins && kept_copy && pull.categories.syncs(kind) {
                judgement = Judgement::Merge;
            }
            let stored = local.and_then(|local| local.records.get(&key.record_id));
            if !pull.categories.syncs(kind) {
                Self::while_off(&key, kind, judgement, base, stored, &record, writes);
                continue;
            }
            // A copy this device keeps to itself takes nothing a pull brings, a deletion included, as on iCloud (0054,
            // Rules for both providers).
            if stored.is_some_and(|stored| stored.standing == Standing::LocalOnly) {
                continue;
            }
            if kind == Kind::HistoryEntry && !self.history_taken(&inputs, base, &record, writes) {
                continue;
            }
            // A store restored while its kind was off merges against the copy the restore left, so what was edited
            // since goes up and the rest takes the server's copy (0054, Store identity).
            let refill = inputs.deferred.get(&key).map(|deferred| {
                writes.undeferred.push(key.clone());
                deferred.fields.as_ref().map(|fields| BaseRow {
                    key: key.clone(),
                    // The copy has no tag of its own, so it never reads as the server's copy unchanged.
                    tag: ChangeTag::Service(String::new()),
                    version: None,
                    revision: None,
                    epoch: None,
                    deleted: None,
                    fields: Some(fields.clone()),
                    created_ms: None,
                })
            });
            let base = match (&refill, judgement) {
                (Some(refill), Judgement::Merge) => refill.as_ref(),
                _ => base,
            };
            self.settle_one(
                pull, &inputs, key, kind, index, judgement, base, stored, record, marker, writes,
            );
        }
        // A conflict is kept before the store takes the server's side of it, so a crash between the two never loses
        // the device's side (0044, Conflict rules).
        if !writes.conflicts.is_empty() {
            self.check_stop()?;
            let mut txn = begin(&self.state).await?;
            for conflict in &writes.conflicts {
                txn.put(Row::Conflict(conflict.clone())).await?;
            }
            self.check_stop()?;
            txn.commit().await?;
        }
        self.write_store(pull, adapters, writes).await
    }

    // What a kind turned off takes from a refill without touching its store: a base the restore lost, which the
    // device's copy goes up on once the kind is on, and, from a store that was restored, the copy the restore left,
    // which the kind merges against once it is read again. Anything else is read again when the kind is turned on.
    fn while_off(
        key: &RecordKey,
        kind: Kind,
        judgement: Judgement,
        base: Option<&BaseRow>,
        stored: Option<&LocalRecord>,
        record: &PulledRecord,
        writes: &mut PageWrites,
    ) {
        match judgement {
            Judgement::LocalWins => {
                writes
                    .bases
                    .extend(settle(key, kind, judgement, base, None, record).base);
            }
            Judgement::PullWins => writes.deferred.push(DeferredRow {
                key: key.clone(),
                record: PulledRecord {
                    fields: stored.map(|stored| stored.fields.clone()),
                    fields_json: None,
                    deleted: None,
                    service: None,
                    ..record.clone()
                },
            }),
            Judgement::Merge => {}
        }
    }

    #[expect(clippy::too_many_arguments, reason = "one record with everything a pull knows of it")]
    fn settle_one(
        &self,
        pull: &Pull,
        inputs: &SettleInputs,
        key: RecordKey,
        kind: Kind,
        index: usize,
        judgement: Judgement,
        base: Option<&BaseRow>,
        stored: Option<&LocalRecord>,
        record: PulledRecord,
        marker: Option<MoveMarker>,
        writes: &mut PageWrites,
    ) {
        let rows = inputs.approvals.get(&key).map_or(&[][..], Vec::as_slice);
        let open = inputs.conflicts.get(&key);
        // A record held whole until the person decides is new to the device: a later copy merges as a create, never
        // against a base the store does not hold.
        let awaiting = stored.is_none() && inputs.awaiting.contains(&key);
        let (base_view, mine) = match open {
            _ if awaiting => (None, None),
            Some(row) => conflict::sides(row, base, stored),
            None => (base.cloned(), stored.cloned()),
        };
        // The merge reads the device's side as it would go up: with what the store cannot hold, and with what waits
        // for the person or was refused at the base's value, except the members an open conflict holds the device's
        // own values of.
        let contested: Vec<String> = open.map(conflict::contested).unwrap_or_default();
        let under_contest = |field: &str| {
            contested.iter().any(|name| {
                let pointer = format!("/{}", name.replace('~', "~0").replace('/', "~1"));
                field == pointer || field.starts_with(&format!("{pointer}/"))
            })
        };
        let held_members: BTreeSet<String> = rows
            .iter()
            .filter(|row| row.decision != ApprovalDecision::Approved && !under_contest(&row.field))
            .map(|row| row.field.clone())
            .collect();
        let mine_side = mine.as_ref().map(|mine| mine.fields.clone());
        let base_fields = base_view.as_ref().and_then(|base| base.fields.as_ref());
        let mine = mine.map(|mine| LocalRecord {
            fields: local_view(kind, pull.scope, &mine.fields, base_fields, &held_members),
            ..mine
        });
        let mut settled = match (marker, stored) {
            (Some(marker), Some(_)) => settle_moved(&key, kind, &marker, mine.as_ref(), &record),
            // Gone from the zone since another device moved it: deleted on iCloud, unless its content changed here
            // since (0054, Deletions made on a device still on iCloud). One this device's CloudKit base names that its
            // store no longer holds is this device's own deletion, which a move with no zone listing still reads.
            (Some(marker), None)
                if !awaiting
                    && pull.arrival.as_deref().is_some_and(|arrival| {
                        !arrival.kept_here(&key) && (arrival.gone(&key) || arrival.deleted_here(&key))
                    }) =>
            {
                settle_moved(&key, kind, &marker, None, &record)
            }
            (Some(_), None) => settle(&key, kind, judgement, None, None, &record),
            (None, _) => settle(&key, kind, judgement, base_view.as_ref(), mine.as_ref(), &record),
        };
        // The row keeps the device's own values in the members it contests, never the merge's view of them, so Keep
        // Mine writes nothing the device did not hold; the members the merge did not contest stay as the merge read
        // them, so a value that waits or was refused is never taken for the device's edit. Against a deletion the
        // device keeps its own copy whole.
        if let Some(conflict) = settled.conflict.as_mut() {
            conflict.mine = if conflict.theirs.is_some() {
                let names = conflict::contested(conflict);
                conflict
                    .mine
                    .as_ref()
                    .map(|view| conflict::overlay(view, mine_side.as_ref(), &names))
            } else {
                mine_side
            };
        }
        let undecided: BTreeSet<String> = rows
            .iter()
            .filter(|row| row.decision != ApprovalDecision::Approved)
            .map(|row| row.field.clone())
            .collect();
        let stored_view = stored.map(|stored| {
            unsettled::approval_view(kind, &stored.fields, base_fields, settled.kept.as_ref(), &undecided)
        });
        let stored_fields = stored_view.as_ref();
        match (&settled.kept, &settled.store) {
            (Some(fields), _) => {
                let mut split = approval::split(kind, &key, stored_fields, fields, rows);
                if let Some(server) = record.fields.as_ref() {
                    unsettled::settle(kind, &mut split.fields, server);
                }
                if split.hold {
                    writes
                        .held
                        .push(held(HeldReason::AwaitingApproval, key.clone(), record.clone()));
                } else if stored_fields != Some(&split.fields) {
                    writes.store.push((
                        index,
                        record.clone(),
                        LocalChange::Put {
                            record_id: key.record_id.clone(),
                            fields: split.fields.clone(),
                        },
                    ));
                }
                writes.approvals.push((key.clone(), split));
            }
            (None, Some(change @ LocalChange::Delete { .. })) => {
                writes.approvals.push((key.clone(), cleared(rows)));
                writes.store.push((index, record.clone(), change.clone()));
            }
            // A tombstone of a record the store does not hold leaves nothing to decide; one the store keeps, as against
            // a policy or a contested deletion, keeps what waits.
            (None, _) if record.deleted.is_some() && stored.is_none() => {
                writes.approvals.push((key.clone(), cleared(rows)));
            }
            (None, _) => {}
        }
        if open.is_some() && settled.base.is_some() && settled.conflict.is_none() {
            writes.resolved.push(key.clone());
        }
        writes.bases.extend(settled.base);
        writes.conflicts.extend(settled.conflict);
        writes.unheld.push(key);
    }

    // A `user` tombstone of a history entry is final: a device refuses its id when it comes back, whatever the server
    // serves (0051, Tombstones), and keeps the ids it saw deleted (0054, `deleted_history`).
    fn history_taken(
        &self,
        inputs: &SettleInputs,
        base: Option<&BaseRow>,
        record: &PulledRecord,
        writes: &mut PageWrites,
    ) -> bool {
        match record.deleted {
            Some(DeletedReason::User) => {
                writes.rows.push(Row::DeletedHistory(DeletedHistoryRow {
                    record_id: record.record_id.clone(),
                }));
                true
            }
            Some(DeletedReason::Policy) => true,
            None => {
                let deleted = base.is_some_and(|base| base.deleted == Some(DeletedReason::User))
                    || inputs.deleted_history.contains(&record.record_id);
                if deleted {
                    tracing::debug!("a history entry came back after its deletion; it stays deleted");
                }
                !deleted
            }
        }
    }

    async fn settle_inputs(&self, keys: &[RecordKey]) -> Result<SettleInputs, SyncError> {
        let mut txn = begin(&self.state).await?;
        let mut inputs = SettleInputs::default();
        let mut scanned: HashSet<(ScopeName, KindName)> = HashSet::new();
        for key in keys {
            if let Some(Row::Base(base)) = txn.get(&RowKey::Base(key.clone())).await? {
                inputs.bases.insert(key.clone(), base);
            }
            if let Some(Row::Conflict(row)) = txn.get(&RowKey::Conflict(key.clone())).await? {
                inputs.conflicts.insert(key.clone(), row);
            }
            if let Some(Row::Held(row)) = txn.get(&RowKey::Held(key.clone())).await?
                && row.reason == HeldReason::AwaitingApproval
            {
                inputs.awaiting.insert(key.clone());
            }
            if let Some(Row::Deferred(row)) = txn.get(&RowKey::Deferred(key.clone())).await? {
                inputs.deferred.insert(key.clone(), row.record);
            }
            if key.kind.known() == Some(Kind::HistoryEntry)
                && txn.get(&RowKey::DeletedHistory(key.record_id.clone())).await?.is_some()
            {
                inputs.deleted_history.insert(key.record_id.clone());
            }
            if scanned.insert((key.scope, key.kind.clone())) {
                for row in txn
                    .scan(&RowRange::ScopeKind(Table::Approvals, key.scope, key.kind.clone()))
                    .await?
                {
                    if let Row::Approval(row) = row {
                        inputs.approvals.entry(row.key.clone()).or_default().push(row);
                    }
                }
            }
        }
        Ok(inputs)
    }

    // One store write per adapter, each after a stop check (P1-M4).
    async fn write_store(
        &self,
        pull: &Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        writes: &mut PageWrites,
    ) -> Result<(), SyncError> {
        let scope = pull.scope;
        let mut grouped: Vec<(usize, Vec<(PulledRecord, LocalChange)>)> = Vec::new();
        for (index, record, change) in writes.store.drain(..) {
            match grouped.iter_mut().find(|(held, _)| *held == index) {
                Some((_, changes)) => changes.push((record, change)),
                None => grouped.push((index, vec![(record, change)])),
            }
        }
        for (index, changes) in grouped {
            if let Some(adapter) = adapters.get(index) {
                let applied = apply_keeping(adapter.as_ref(), scope, changes, || self.check_stop()).await?;
                for record in applied.refused {
                    let key = RecordKey::new(scope, record.kind.clone(), record.record_id.clone());
                    // Only the sealed copy of this very record stands in for it; a tombstone carries no plaintext.
                    let record = match pull.sealed.get(&key) {
                        Some(sealed) if record.deleted.is_none() && sealed.tag == record.tag => sealed.clone(),
                        _ => record,
                    };
                    let refilling = pull.held_refills.contains(&key)
                        || record.kind.known().is_some_and(|kind| pull.pull_wins.contains(&kind));
                    writes.refuse(key, record, refilling);
                }
            }
        }
        Ok(())
    }

    pub(super) async fn commit_page(&self, writes: PageWrites, row: Option<&ScopeRow>) -> Result<(), SyncError> {
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        for key in writes.unheld {
            txn.delete(&RowKey::Held(key)).await?;
        }
        for base in writes.bases {
            txn.put(Row::Base(base)).await?;
        }
        for key in writes.dropped {
            txn.delete(&RowKey::Base(key)).await?;
        }
        for held in writes.held {
            txn.put(Row::Held(held)).await?;
        }
        for key in writes.resolved {
            txn.delete(&RowKey::Conflict(key)).await?;
        }
        for conflict in writes.conflicts {
            txn.put(Row::Conflict(conflict)).await?;
        }
        for (key, split) in &writes.approvals {
            approval::write(txn.as_mut(), key, split).await?;
        }
        for key in writes.undeferred {
            txn.delete(&RowKey::Deferred(key)).await?;
        }
        for row in writes.deferred {
            txn.put(Row::Deferred(row)).await?;
        }
        for row in writes.rows {
            txn.put(row).await?;
        }
        for key in writes.refilled {
            txn.delete(&key).await?;
        }
        if let Some(row) = row {
            txn.put(Row::Scope(row.clone())).await?;
        }
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    // Caught up: the key objects as one set, then the envelopes, then the bases the server no longer holds go, so what
    // they stood for goes up as a create. The cursor and the version in force commit together, and so do the stores
    // this snapshot was the last refill of. A refill against a new epoch adopts it only once the key objects went back.
    async fn finish_snapshot(
        &self,
        ctx: &mut PassCtx,
        pull: &mut Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        row: &mut ScopeRow,
        info: &ScopeInfo,
    ) -> Result<(), SyncError> {
        let mut writes = PageWrites::default();
        let keys = std::mem::take(&mut pull.held_keys);
        if !keys.is_empty() {
            pull.in_force = self.arrive_set(pull.scope, keys).await?;
        }
        // Versions only move forward: a snapshot that served no key object leaves the one in force as it was.
        pull.in_force = pull.in_force.max(row.key_version);
        let mut opened = Vec::new();
        for record in std::mem::take(&mut pull.held_envelopes) {
            let key = RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone());
            if !pull.can_open {
                writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record));
                continue;
            }
            match self.envelope_opens(pull.scope, &record, None).await? {
                Opens::Taken => opened.push(record),
                Opens::Refused => writes.held.push(held(HeldReason::Unreadable, key, record)),
                Opens::Waits => writes.held.push(held(HeldReason::AwaitingDeviceApproval, key, record)),
            }
        }
        self.settle_all(pull, adapters, opened, &mut writes).await?;
        ctx.report.store_refused.extend(writes.refused.iter().cloned());
        let before = row.clone();
        row.cursor.clone_from(&pull.cursor);
        row.key_version = pull.in_force;
        row.caught_up = true;
        row.read_kinds.clone_from(&pull.reading);
        if pull.older_read {
            row.older_cursor.clone_from(&pull.older_cursor);
        }
        // Before approval a personal pull serves key objects only: it settles no base, store or epoch.
        let whole = pull.scope != ScopeName::Personal || info.approved == Some(true);
        // A refill that kept envelopes it could not check is not done for them: their store and the epoch wait for a
        // pass that can, so that pass refills them by the same rule. Only a device that could check none leaves it
        // open; envelopes that wait for a team's key are held by id, and the store settles, so its other copies stop
        // refilling.
        let refilling = pull.cut.is_some() || pull.pull_wins.contains(&Kind::SecretEnvelope);
        let unchecked = refilling
            && !pull.can_open
            && writes
                .held
                .iter()
                .any(|row| row.reason == HeldReason::AwaitingDeviceApproval);
        if whole {
            if pull.scope != ScopeName::History {
                writes.dropped = self.unseen_bases(pull).await?;
            }
            let envelopes = adapters
                .iter()
                .find(|adapter| adapter.kind() == Kind::SecretEnvelope)
                .map(|adapter| adapter.store().to_owned());
            let except = envelopes.filter(|_| unchecked);
            writes.refilled = self.settled_refills(ctx, pull.scope, except.as_deref()).await?;
            // In a history snapshot that stopped at its window this also lets go of older entries kept for the keys;
            // paging back serves them again and opens them then.
            if pull.can_open {
                writes
                    .unheld
                    .extend(self.waiting_envelopes(pull.scope).await?.into_iter().filter(|key| {
                        !pull
                            .seen
                            .contains(&(key.kind.as_str().to_owned(), key.record_id.clone()))
                    }));
            }
            writes.undeferred.extend(self.deferred_unseen(pull).await?);
            if row.refill {
                if !unchecked {
                    ctx.adopt.push((pull.scope, ctx.body.epoch, info.epochs.clone()));
                }
            } else {
                row.epoch = Some(ctx.body.epoch);
                row.lineage.clone_from(&info.epochs);
            }
        }
        if !writes.is_empty() || *row != before {
            self.commit_page(writes, Some(row)).await?;
        }
        if whole && !unchecked {
            ctx.snapshots_done.insert(pull.scope);
        }
        Ok(())
    }

    // The history view asks for entries older than the window: one older page, settled as a snapshot's, and the
    // cursor it leaves for the next. True while older entries remain (0051, Pull; F18).
    pub(super) async fn load_older(&self) -> Result<bool, SyncError> {
        let scope = ScopeName::History;
        let Some(mut row) = self.scope_row(scope).await? else {
            return Ok(false);
        };
        let Some(cursor) = row.older_cursor.clone() else {
            return Ok(false);
        };
        self.check_stop()?;
        let request = PullRequest {
            scope,
            cursor: Some(cursor),
            limit: None,
            proof: self.scope_proof(scope).await?,
        };
        let page = match self.transport.pull(request).await {
            // Another epoch: the next pass refills the history, and paging back starts again from it.
            Err(TransportError::CursorExpired) => {
                row.older_cursor = None;
                self.commit_page(PageWrites::default(), Some(&row)).await?;
                return Ok(false);
            }
            other => other?,
        };
        let adapters = self.adapters.in_scope(scope);
        let mut pull = Pull {
            scope,
            snapshot: true,
            cut: None,
            pull_wins: HashSet::new(),
            held_refills: self.held_refills(scope).await?,
            cursor: None,
            older_cursor: None,
            in_force: None,
            held_keys: Vec::new(),
            held_envelopes: Vec::new(),
            seen: HashSet::new(),
            can_open: self.history_opens_now().await,
            buffered: 0,
            reading: Vec::new(),
            new_waits: false,
            window: None,
            older: false,
            older_read: false,
            categories: self.categories(),
            arrival: None,
            sealed: HashMap::new(),
        };
        row.older_cursor = page.cursor.clone().filter(|_| !page.records.is_empty());
        let writes = self.take_page(&mut pull, &adapters, page.records).await?;
        self.commit_page(writes, Some(&row)).await?;
        Ok(row.older_cursor.is_some())
    }

    // Copies a refill kept for a kind that was off, which a snapshot reading that kind no longer serves: what they
    // stood for goes up as a create, as the refill would have sent it.
    async fn deferred_unseen(&self, pull: &Pull) -> Result<Vec<RecordKey>, SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Deferred, pull.scope))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Deferred(row) => Some(row.key),
                _ => None,
            })
            .filter(|key| pull.reading.contains(&key.kind))
            .filter(|key| {
                !pull
                    .seen
                    .contains(&(key.kind.as_str().to_owned(), key.record_id.clone()))
            })
            .collect())
    }

    // Envelopes, and in the history scope entries, kept until the keys could open them.
    async fn waiting_envelopes(&self, scope: ScopeName) -> Result<Vec<RecordKey>, SyncError> {
        let sealed = match scope {
            ScopeName::History => Kind::HistoryEntry,
            ScopeName::Personal | ScopeName::Team(_) => Kind::SecretEnvelope,
        };
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::ScopeKind(Table::Held, scope, KindName::of(sealed)))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(row) if row.reason == HeldReason::AwaitingDeviceApproval => Some(row.key),
                _ => None,
            })
            .collect())
    }

    // A key object's base stays: the push-back judges by its epoch and revision whether a restore lost it, and the
    // key object goes back from `key_objects`, never as a create of the diff (0051, After a restore).
    async fn unseen_bases(&self, pull: &Pull) -> Result<Vec<RecordKey>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let rows = txn.scan(&RowRange::Scope(Table::Bases, pull.scope)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Base(base) if !base.key.kind.is_key() => Some(base.key),
                _ => None,
            })
            .filter(|key| {
                !pull
                    .seen
                    .contains(&(key.kind.as_str().to_owned(), key.record_id.clone()))
            })
            .collect())
    }
}

// The history scope's snapshot pages newest first: the pull follows each page's `cursor` to older entries until its
// window holds what the device keeps, then follows `changes_cursor`, and keeps the last `cursor` to page back on
// demand (0051, Pull; F18).
fn next_cursor(pull: &mut Pull, page: &PulledPage) -> Option<Cursor> {
    if pull.older && page.changes_cursor.is_some() {
        if let Some(left) = pull.window.as_mut() {
            *left = left.saturating_sub(page.records.len());
        }
        let older = page.cursor.clone().filter(|_| !page.records.is_empty());
        if older.is_some() && pull.window != Some(0) {
            return older;
        }
        pull.older = false;
        pull.older_read = true;
        pull.older_cursor = older;
        return page.changes_cursor.clone();
    }
    // A page with no records moved nothing: the cursor held resumes at the same place, and keeping it spares a commit.
    if page.records.is_empty() && pull.cursor.is_some() {
        return pull.cursor.clone();
    }
    page.cursor.clone().or_else(|| pull.cursor.clone())
}

async fn local_indexes(
    scope: ScopeName,
    adapters: &[Arc<dyn RecordAdapter>],
    records: &[PulledRecord],
) -> Result<HashMap<usize, LocalIndex>, SyncError> {
    let kinds: HashSet<Kind> = records.iter().filter_map(|record| record.kind.known()).collect();
    let mut indexes = HashMap::new();
    for (index, adapter) in adapters.iter().enumerate() {
        if !kinds.contains(&adapter.kind()) {
            continue;
        }
        let local = adapter.records(scope).await?;
        indexes.insert(
            index,
            LocalIndex {
                records: local
                    .records
                    .into_iter()
                    .map(|record| (record.record_id.clone(), record))
                    .collect(),
                unreadable: local.unreadable.into_iter().collect(),
            },
        );
    }
    Ok(indexes)
}
