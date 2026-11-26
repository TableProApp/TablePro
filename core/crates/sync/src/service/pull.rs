// A scope's pull (0051, Pull; 0054, A pass): pages from the cursor, each written to the stores, then the bases, then
// the cursor with the key version in force at it, so a crash replays a page with no effect. A snapshot's key objects
// and envelopes wait until it is caught up; it commits its cursor only then.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tablepro_keys::encoding::Version;
use tablepro_records::Kind;

use super::keys::{Family, KeyMark, Opens, family};
use super::refill::Cut;
use super::scopes::refresh;
use super::{PassCtx, ServiceSync, begin};
use crate::api::adapter::{LocalChange, LocalRecord, RecordAdapter};
use crate::api::error::SyncError;
use crate::api::ids::{Cursor, KindName, RecordKey, ScopeName};
use crate::api::key_flows::{ArrivalOrder, CaughtUp};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{BaseRow, ConflictRow, HeldReason, HeldRow, Row, RowKey, RowRange, ScopeRow, Table};
use crate::api::transport::{Proof, PullRequest, PulledPage, PulledRecord, TransportError};
use crate::engine::{Judgement, base_of, settle};

struct Pull {
    scope: ScopeName,
    snapshot: bool,
    // A new epoch: each base is judged against the cut that ended its history.
    cut: Option<Cut>,
    // Kinds whose store was restored, replaced or never seen: the pull wins.
    pull_wins: HashSet<Kind>,
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

    fn judge(&self, kind: Kind, base: Option<&BaseRow>, record: &PulledRecord) -> Judgement {
        if self.pull_wins.contains(&kind) {
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
    store: Vec<(usize, LocalChange)>,
    bases: Vec<BaseRow>,
    dropped: Vec<RecordKey>,
    held: Vec<HeldRow>,
    unheld: Vec<RecordKey>,
    conflicts: Vec<ConflictRow>,
    // Rows of other tables that settle in the same commit, as a refilled store's identity.
    rows: Vec<Row>,
}

impl PageWrites {
    fn is_empty(&self) -> bool {
        self.store.is_empty()
            && self.bases.is_empty()
            && self.dropped.is_empty()
            && self.held.is_empty()
            && self.unheld.is_empty()
            && self.conflicts.is_empty()
            && self.rows.is_empty()
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
            ScopeName::Personal | ScopeName::History => self.proofs.dpop_key().await?.map_or(Proof::None, Proof::Dpop),
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
        let pull_wins: HashSet<Kind> = adapters
            .iter()
            .filter(|adapter| ctx.refills(adapter.store()))
            .map(|adapter| adapter.kind())
            .collect();
        let can_open = ctx.keys_ready;
        // Envelopes kept while the device could not check them are read again in a snapshot once it can, which
        // serves each one's current copy after the key objects (0051, Pull). Once a snapshot judged them, only a change
        // of the keys reads them again, so one under a key this account was never given refills nothing.
        let waiting = can_open
            && self.holds_scope_key(scope).await?
            && !self.waiting_envelopes(scope).await?.is_empty()
            && waited.get(&scope) != Some(&self.key_mark(scope, can_open).await?);
        // A build that reads a kind the last pull did not fetches again what it held for it (0054, Rules).
        let mut reading: Vec<KindName> = adapters.iter().map(|adapter| KindName::of(adapter.kind())).collect();
        reading.sort();
        let reads_more = reading.iter().any(|kind| !row.read_kinds.contains(kind));
        let snapshot = row.cursor.is_none() || row.refill || !pull_wins.is_empty() || waiting || reads_more;
        let mut pull = Pull {
            scope,
            snapshot,
            cut: row.refill.then(|| Cut::new(&row.lineage, &info.epochs)),
            pull_wins,
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
        let caught_up = self.pull_pages(ctx, &mut pull, &adapters, &mut row).await?;
        if pull.snapshot {
            self.finish_snapshot(ctx, &mut pull, &adapters, &mut row, info).await?;
            if self.waiting_envelopes(scope).await?.is_empty() {
                waited.remove(&scope);
            } else {
                waited.insert(scope, self.key_mark(scope, can_open).await?);
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
            self.stop.check()?;
            let request = PullRequest {
                scope: pull.scope,
                cursor: pull.cursor.clone(),
                limit: None,
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
        for record in records {
            pull.seen
                .insert((record.kind.as_str().to_owned(), record.record_id.clone()));
            let key = RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone());
            // A live record always carries its fields; one without them is no deletion this device would sign.
            if record.deleted.is_none() && record.fields.is_none() {
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
        self.stop.check()?;
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
        let bases = self.bases_of(&keys).await?;
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
            let base = bases.get(&key);
            let judgement = pull.judge(kind, base, &record);
            let mine = local.and_then(|local| local.records.get(&key.record_id));
            let settled = settle(&key, kind, judgement, base, mine, &record);
            writes.store.extend(settled.store.map(|change| (index, change)));
            writes.bases.extend(settled.base);
            writes.conflicts.extend(settled.conflict);
            writes.unheld.push(key);
        }
        self.write_store(pull.scope, adapters, writes).await
    }

    async fn bases_of(&self, keys: &[RecordKey]) -> Result<HashMap<RecordKey, BaseRow>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let mut bases = HashMap::new();
        for key in keys {
            if let Some(Row::Base(base)) = txn.get(&RowKey::Base(key.clone())).await? {
                bases.insert(key.clone(), base);
            }
        }
        Ok(bases)
    }

    // One store write per adapter, each after a stop check (P1-M4).
    async fn write_store(
        &self,
        scope: ScopeName,
        adapters: &[Arc<dyn RecordAdapter>],
        writes: &mut PageWrites,
    ) -> Result<(), SyncError> {
        let mut grouped: Vec<(usize, Vec<LocalChange>)> = Vec::new();
        for (index, change) in writes.store.drain(..) {
            match grouped.iter_mut().find(|(held, _)| *held == index) {
                Some((_, changes)) => changes.push(change),
                None => grouped.push((index, vec![change])),
            }
        }
        for (index, changes) in grouped {
            self.stop.check()?;
            if let Some(adapter) = adapters.get(index) {
                adapter.apply(scope, changes).await?;
            }
        }
        Ok(())
    }

    pub(super) async fn commit_page(&self, writes: PageWrites, row: Option<&ScopeRow>) -> Result<(), SyncError> {
        self.stop.check()?;
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
        for conflict in writes.conflicts {
            txn.put(Row::Conflict(conflict)).await?;
        }
        for row in writes.rows {
            txn.put(row).await?;
        }
        if let Some(row) = row {
            txn.put(Row::Scope(row.clone())).await?;
        }
        self.stop.check()?;
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
        let before = row.clone();
        row.cursor.clone_from(&pull.cursor);
        row.key_version = pull.in_force;
        row.caught_up = true;
        row.read_kinds.clone_from(&pull.reading);
        if pull.older_cursor.is_some() {
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
            writes.rows = self.settled_stores(ctx, pull.scope, except.as_deref()).await?;
            if pull.can_open {
                writes
                    .unheld
                    .extend(self.waiting_envelopes(pull.scope).await?.into_iter().filter(|key| {
                        !pull
                            .seen
                            .contains(&(key.kind.as_str().to_owned(), key.record_id.clone()))
                    }));
            }
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

    async fn waiting_envelopes(&self, scope: ScopeName) -> Result<Vec<RecordKey>, SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::ScopeKind(
                Table::Held,
                scope,
                KindName::of(Kind::SecretEnvelope),
            ))
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

// The history scope's snapshot pages newest first: its first page's `cursor` pages older entries on demand, and the
// pull follows `changes_cursor` (0051, Pull).
fn next_cursor(pull: &mut Pull, page: &PulledPage) -> Option<Cursor> {
    if pull.scope == ScopeName::History && pull.cursor.is_none() && page.changes_cursor.is_some() {
        pull.older_cursor.clone_from(&page.cursor);
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
