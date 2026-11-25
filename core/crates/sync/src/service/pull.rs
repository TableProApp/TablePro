// A scope's pull (0051, Pull; 0054, A pass): pages from the cursor, each written to the stores, then the bases, then
// the cursor with the key version in force at it, so a crash replays a page with no effect. A snapshot's key objects
// and envelopes wait until it is caught up; it commits its cursor only then.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tablepro_keys::encoding::Version;
use tablepro_records::Kind;

use super::keys::{Family, family};
use super::refill::Cut;
use super::scopes::refresh;
use super::{PassCtx, ServiceSync, begin};
use crate::api::adapter::{LocalChange, LocalRecord, RecordAdapter};
use crate::api::error::SyncError;
use crate::api::ids::{Cursor, RecordKey, ScopeName};
use crate::api::key_flows::ArrivalOrder;
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
}

impl Pull {
    fn restart_as_snapshot(&mut self) {
        self.snapshot = true;
        self.cursor = None;
        self.in_force = None;
        self.held_keys.clear();
        self.held_envelopes.clear();
        self.seen.clear();
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
}

impl PageWrites {
    fn is_empty(&self) -> bool {
        self.store.is_empty()
            && self.bases.is_empty()
            && self.dropped.is_empty()
            && self.held.is_empty()
            && self.unheld.is_empty()
            && self.conflicts.is_empty()
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
    fn scope_proof(ctx: &PassCtx, scope: ScopeName) -> Proof {
        match scope {
            ScopeName::Team(_) => Proof::None,
            ScopeName::Personal | ScopeName::History => ctx.key.clone().map_or(Proof::None, Proof::Dpop),
        }
    }

    pub(super) async fn pull_scope(&self, ctx: &mut PassCtx, info: &ScopeInfo) -> Result<(), SyncError> {
        let scope = info.scope;
        let adapters = self.adapters.adapters(scope);
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
        let snapshot = row.cursor.is_none() || row.refill || !pull_wins.is_empty();
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
        self.pull_pages(ctx, &mut pull, &adapters, &mut row).await?;
        if pull.snapshot {
            self.finish_snapshot(ctx, &mut pull, &adapters, &mut row, info).await?;
        }
        self.read_roster(info).await;
        Ok(())
    }

    async fn pull_pages(
        &self,
        ctx: &mut PassCtx,
        pull: &mut Pull,
        adapters: &[Arc<dyn RecordAdapter>],
        row: &mut ScopeRow,
    ) -> Result<(), SyncError> {
        loop {
            self.stop.check()?;
            let request = PullRequest {
                scope: pull.scope,
                cursor: pull.cursor.clone(),
                limit: None,
                proof: Self::scope_proof(ctx, pull.scope),
            };
            let page = match self.transport.pull(request).await {
                // A snapshot, and a refill when the scopes body showed a new epoch (0051, `cursor_expired`).
                Err(TransportError::CursorExpired) if !pull.snapshot => {
                    pull.restart_as_snapshot();
                    continue;
                }
                other => other?,
            };
            let caught_up = page.caught_up || page.records.is_empty();
            let next = next_cursor(pull, &page);
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
                return Ok(());
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
        for record in records {
            pull.seen
                .insert((record.kind.as_str().to_owned(), record.record_id.clone()));
            if let Some(next) = family(pull.scope, &record.kind) {
                if pull.snapshot {
                    pull.held_keys.push(record);
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
                    pull.held_envelopes.push(record);
                    continue;
                }
                if !self.envelope_opens(pull.scope, &record, pull.in_force).await {
                    let key = RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone());
                    writes.held.push(held(HeldReason::Unreadable, key, record));
                    continue;
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
        let applied = self.arrive(pull.scope, family, records, ArrivalOrder::InOrder).await?;
        if applied.in_force.is_some() {
            pull.in_force = applied.in_force;
        }
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
        let locals = local_indexes(adapters, &records).await?;
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
        self.write_store(adapters, writes).await
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
    async fn write_store(&self, adapters: &[Arc<dyn RecordAdapter>], writes: &mut PageWrites) -> Result<(), SyncError> {
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
                adapter.apply(changes).await?;
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
        if let Some(row) = row {
            txn.put(Row::Scope(row.clone())).await?;
        }
        self.stop.check()?;
        txn.commit().await?;
        Ok(())
    }

    // Caught up: the key objects as one set, then the envelopes, then the bases the server no longer holds go, so what
    // they stood for goes up as a create. The cursor, the version in force and the epoch commit together.
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
        let mut opened = Vec::new();
        for record in std::mem::take(&mut pull.held_envelopes) {
            if self.envelope_opens(pull.scope, &record, None).await {
                opened.push(record);
            } else {
                let key = RecordKey::new(pull.scope, record.kind.clone(), record.record_id.clone());
                writes.held.push(held(HeldReason::Unreadable, key, record));
            }
        }
        self.settle_all(pull, adapters, opened, &mut writes).await?;
        if pull.scope != ScopeName::History {
            writes.dropped = self.unseen_bases(pull).await?;
        }
        let before = row.clone();
        row.cursor.clone_from(&pull.cursor);
        row.key_version = pull.in_force;
        row.epoch = Some(ctx.body.epoch);
        row.lineage.clone_from(&info.epochs);
        row.refill = false;
        row.caught_up = true;
        if pull.older_cursor.is_some() {
            row.older_cursor.clone_from(&pull.older_cursor);
        }
        if !writes.is_empty() || *row != before {
            self.commit_page(writes, Some(row)).await?;
        }
        // Before approval a personal pull serves key objects only, so the stores it holds are not settled yet.
        if pull.scope != ScopeName::Personal || info.approved == Some(true) {
            ctx.snapshots_done.insert(pull.scope);
        }
        Ok(())
    }

    async fn unseen_bases(&self, pull: &Pull) -> Result<Vec<RecordKey>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let rows = txn.scan(&RowRange::Scope(Table::Bases, pull.scope)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Base(base) => Some(base.key),
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
    adapters: &[Arc<dyn RecordAdapter>],
    records: &[PulledRecord],
) -> Result<HashMap<usize, LocalIndex>, SyncError> {
    let kinds: HashSet<Kind> = records.iter().filter_map(|record| record.kind.known()).collect();
    let mut indexes = HashMap::new();
    for (index, adapter) in adapters.iter().enumerate() {
        if !kinds.contains(&adapter.kind()) {
            continue;
        }
        let local = adapter.records().await?;
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
