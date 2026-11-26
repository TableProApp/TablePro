// The TablePro Sync pass (0051, Protocol; Restore; 0054, The engine): the scopes body, then each scope's pull, the key
// objects a new epoch needs pushed back, the flows to resume, each scope's push with its outbox, and the stop reports.

mod identity;
mod keys;
mod pull;
mod push;
mod refill;
mod scopes;

pub use identity::unsent_changes;
use push::AfterPush;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_keys::encoding::KeyPurpose;
use tablepro_records::Kind;

use crate::adapters::approval::Queue;
use crate::adapters::categories::DeviceCategories;
use crate::adapters::conflict::Conflicts;
use crate::api::adapter::StoreStamp;
use crate::api::control::{
    ConflictChoice, HeldRecord, HeldRecordReason, NewIdentityChoice, NewIdentityPlan, PassReason, PendingApproval,
    SyncCategories, SyncControl, SyncPhase, SyncStatus, TeamConflict,
};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, KindName, RecordKey, ScopeName};
use crate::api::key_flows::{KeyFlows, KeyState, LockCause};
use crate::api::scopes::{LineageEpoch, ScopeInfo, ScopesBody};
use crate::api::state::{
    KeyVersionState, Provider, Row, RowKey, RowRange, StateStore, StateTxn, StoppedCause, StoreRow, StoresKindRow,
    Table,
};
use crate::api::transport::{ServiceTransport, TransportError};
use crate::engine::{Adapters, Clock, EngineEvents, EngineHooks, Journal, JournalEntry, JournalIds, Pass, StopSignal};

pub struct ServiceParts {
    pub transport: Arc<dyn ServiceTransport>,
    pub state: Arc<dyn StateStore>,
    pub adapters: Adapters,
    pub keys: Arc<dyn KeyFlows>,
    pub hooks: Arc<EngineHooks>,
    pub clock: Arc<dyn Clock>,
    pub stop: StopSignal,
    pub journal: Journal,
    pub events: Option<Arc<dyn EngineEvents>>,
    // The categories the app opened sync with (`SyncConfig.categories`), so no pass runs before they are known.
    pub categories: SyncCategories,
    // This account follows another account or server on this device: the changes the last one's file held unsent,
    // which the opener counts with `unsent_changes`. Nothing personal goes up until the person chooses (0054,
    // Another account or server).
    pub follows: Option<u64>,
}

pub struct ServiceSync {
    transport: Arc<dyn ServiceTransport>,
    state: Arc<dyn StateStore>,
    adapters: Adapters,
    keys: Arc<dyn KeyFlows>,
    hooks: Arc<EngineHooks>,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
    journal: Journal,
    events: Option<Arc<dyn EngineEvents>>,
    // One pass at a time per state file (0054, Scheduling).
    session: tokio::sync::Mutex<Session>,
    status: Mutex<SyncStatus>,
    categories: Mutex<DeviceCategories>,
    // The history entries this device keeps, its retention, which a snapshot takes newest first; None takes all.
    history_window: Mutex<Option<u32>>,
    follows: Option<u64>,
}

#[derive(Debug, Default)]
struct Session {
    etag: Option<String>,
    body: Option<ScopesBody>,
    stale_handled: bool,
    // What each scope's waiting envelopes were last judged against in a snapshot.
    waited: HashMap<ScopeName, keys::KeyMark>,
}

// What one pass did, for the status and for tests.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PassReport {
    pub pulled: usize,
    pub pushed: usize,
    pub conflicts: usize,
    pub refused: Vec<(RecordKey, String)>,
    pub skipped: Vec<(ScopeName, &'static str)>,
    pub pull_only: bool,
    pub queued: usize,
    // What held the push of the own scopes back.
    pub push_wait: Option<crate::api::state::PushWait>,
}

// One store as the pass found it: its identity at the start, and the kinds that still owe a refill.
#[derive(Debug, Clone)]
struct StoreSeen {
    start: StoreStamp,
    stored: Option<StoreStamp>,
    owed: BTreeSet<Kind>,
    // This pass found the store restored, replaced or new and marked its kinds.
    marked: bool,
    scopes: HashSet<ScopeName>,
}

struct PassCtx {
    body: ScopesBody,
    // The device held a key when the pass began, which decides the scopes it reaches; each call reads the key itself.
    keyed: bool,
    stores: HashMap<String, StoreSeen>,
    snapshots_done: HashSet<ScopeName>,
    // A refill against a new epoch was pulled, and the key objects still have to go back before anything else.
    new_epoch: bool,
    pushed_back: Option<EpochId>,
    // The scopes whose refill snapshot is done, with the epoch they refilled against: each adopts it and its lineage
    // once the push-back for that epoch answered.
    adopt: Vec<(ScopeName, EpochId, Vec<LineageEpoch>)>,
    // Nothing personal syncs while the device is locked, and no secret goes up under a stopped or ended key.
    locked: bool,
    approved: bool,
    // This device's own key state says it holds its keys, whatever the server says: only then is an envelope checked
    // or sealed.
    keys_ready: bool,
    // A journal pass diffs only these records.
    named: Option<JournalIds>,
    // The categories as the pass began.
    categories: DeviceCategories,
    // What each history entry sealed this pass was before sealing, so a refusal is remembered by it.
    sealed_prints: HashMap<RecordKey, [u8; 32]>,
    report: PassReport,
}

impl PassCtx {
    fn owes(&self, store: &str, kind: Kind) -> bool {
        self.stores.get(store).is_some_and(|seen| seen.owed.contains(&kind))
    }

    fn marked(&self, store: &str) -> bool {
        self.stores.get(store).is_some_and(|seen| seen.marked)
    }
}

// A whole-request refusal that ends one scope's sync this pass and leaves the others to go on.
fn scope_refusal(error: &SyncError) -> Option<&'static str> {
    match error {
        SyncError::Transport(
            error @ (TransportError::SeatRequired | TransportError::NotFound | TransportError::DeviceNotApproved),
        ) => Some(error.code()),
        _ => None,
    }
}

const ROUNDS: usize = 3;

pub(crate) async fn begin(state: &Arc<dyn StateStore>) -> Result<Box<dyn StateTxn>, SyncError> {
    state.begin().await.map_err(SyncError::from)
}

impl ServiceSync {
    pub fn new(parts: ServiceParts) -> Self {
        Self {
            transport: parts.transport,
            state: parts.state,
            adapters: parts.adapters,
            keys: parts.keys,
            hooks: parts.hooks,
            clock: parts.clock,
            stop: parts.stop,
            journal: parts.journal,
            events: parts.events,
            session: tokio::sync::Mutex::new(Session::default()),
            status: Mutex::new(SyncStatus {
                provider: Some(Provider::Service),
                phase: SyncPhase::Idle,
                last_pass_ms: None,
                problem: None,
                waiting_approvals: 0,
                conflicts: 0,
                held: 0,
                queued_changes: 0,
            }),
            categories: Mutex::new(DeviceCategories::from(&parts.categories)),
            history_window: Mutex::new(None),
            follows: parts.follows,
        }
    }

    pub(crate) fn categories(&self) -> DeviceCategories {
        self.categories.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub(crate) fn history_window(&self) -> Option<u32> {
        *self.history_window.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // The app's history retention, in entries: a snapshot of the history scope takes that many, newest first, and the
    // history view pages back for older ones (0051, Pull; F18).
    pub fn set_history_window(&self, entries: Option<u32>) {
        *self.history_window.lock().unwrap_or_else(PoisonError::into_inner) = entries;
    }

    fn queue(&self) -> Queue<'_> {
        Queue {
            state: &self.state,
            adapters: &self.adapters,
        }
    }

    fn conflict_table(&self) -> Conflicts<'_> {
        Conflicts {
            state: &self.state,
            adapters: &self.adapters,
        }
    }

    // A decision changed the stores and the counts: the app reads them again, and the record goes up soon.
    fn decided(&self, key: &RecordKey) {
        if let Some(kind) = key.kind.known() {
            self.journal.changed(&[JournalEntry {
                kind,
                written: vec![key.record_id.clone()],
                deleted: Vec::new(),
            }]);
        }
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }

    pub fn stop_signal(&self) -> &StopSignal {
        &self.stop
    }

    // Where each store's write path tells what it wrote (0060).
    pub fn journal(&self) -> &Journal {
        &self.journal
    }

    fn status_lock(&self) -> MutexGuard<'_, SyncStatus> {
        self.status.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_phase(&self, phase: SyncPhase) {
        self.status_lock().phase = phase;
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }

    pub async fn run_pass(&self, why: PassReason) -> Result<PassReport, SyncError> {
        let mut session = self.session.lock().await;
        tracing::debug!(?why, "sync pass");
        self.set_phase(SyncPhase::Syncing);
        let taken = self.journal.take();
        let named = (why == PassReason::Journal).then(|| taken.clone());
        let journal_only = named.is_some();
        let outcome = self.run(&mut session, named).await;
        if outcome.is_err() {
            self.journal.give_back(taken);
        }
        if let Err(SyncError::Transport(TransportError::DeviceRemoved)) = &outcome {
            crate::api::key_flows::KeyHooks::lock(self.hooks.as_ref(), LockCause::DeviceRemoved);
        }
        self.finish(&outcome, journal_only).await;
        outcome
    }

    async fn run(&self, session: &mut Session, named: Option<JournalIds>) -> Result<PassReport, SyncError> {
        self.stop.check()?;
        self.refill_stale_file(session).await?;
        self.owe_account_choice().await?;
        self.queue().finish_decided().await?;
        let body = self.poll_scopes(session).await?;
        let keyed = self.keys.dpop_key().await?.is_some();
        let approved = body
            .scopes
            .iter()
            .any(|info| info.scope == ScopeName::Personal && info.approved == Some(true));
        let mut ctx = PassCtx {
            body,
            keyed,
            stores: HashMap::new(),
            snapshots_done: HashSet::new(),
            new_epoch: false,
            pushed_back: None,
            adopt: Vec::new(),
            locked: false,
            approved,
            keys_ready: false,
            named,
            categories: self.categories(),
            sealed_prints: HashMap::new(),
            report: PassReport::default(),
        };
        self.read_key_state(&mut ctx).await?;
        let scopes = self.reachable(&ctx);
        self.read_stores(&mut ctx, &scopes).await?;
        // Each scope as the newest scopes body says, which a re-read after an expired cursor may have replaced.
        let names: Vec<ScopeName> = scopes.iter().map(|info| info.scope).collect();
        for scope in &names {
            if let Some(info) = ctx.body.scopes.iter().find(|info| info.scope == *scope).cloned() {
                self.pull_or_skip(&mut ctx, session, &info).await?;
            }
        }
        self.push_back(&mut ctx).await?;
        self.resume_flows().await;
        for scope in &names {
            if let Some(info) = ctx.body.scopes.iter().find(|info| info.scope == *scope).cloned() {
                self.push_rounds(&mut ctx, session, &info).await?;
            }
        }
        self.write_stores(&ctx).await?;
        self.stop_actions(&ctx).await?;
        Ok(ctx.report)
    }

    // An expired cursor reads the scopes body again first, so a new epoch behind it refills (0051, `cursor_expired`).
    async fn pull_or_skip(&self, ctx: &mut PassCtx, session: &mut Session, info: &ScopeInfo) -> Result<(), SyncError> {
        let mut pulled = self.pull_scope(ctx, &mut session.waited, info).await;
        if let Err(SyncError::Transport(TransportError::CursorExpired)) = pulled {
            ctx.body = self.poll_scopes(session).await?;
            let Some(fresh) = ctx.body.scopes.iter().find(|held| held.scope == info.scope).cloned() else {
                return Ok(());
            };
            pulled = self.pull_scope(ctx, &mut session.waited, &fresh).await;
        }
        match pulled {
            Err(error) => match scope_refusal(&error) {
                Some(code) => {
                    ctx.report.skipped.push((info.scope, code));
                    Ok(())
                }
                None => Err(error),
            },
            Ok(()) => Ok(()),
        }
    }

    // What outlives the process: the lock the key flows report and the scopes whose key version stopped or ended
    // (0054, `key_versions`), which the hooks hold for the pass as the one gate a flow's calls then move. A personal or
    // history key that stops or ends locks the device, so only a team's row holds a scope's secrets on its own.
    async fn read_key_state(&self, ctx: &mut PassCtx) -> Result<(), SyncError> {
        let state = self.keys.key_state().await;
        let mut stopped = HashMap::new();
        let mut ended = HashMap::new();
        let mut txn = begin(&self.state).await?;
        for row in txn.scan(&RowRange::Table(Table::KeyVersions)).await? {
            let Row::KeyVersion(row) = row else { continue };
            let scope = match row.purpose {
                KeyPurpose::History => ScopeName::History,
                KeyPurpose::Personal | KeyPurpose::Team => row.scope,
            };
            match row.state {
                KeyVersionState::Ok => {}
                KeyVersionState::Stopped => {
                    stopped.insert(scope, row.stopped_cause.unwrap_or(StoppedCause::CatchUp));
                }
                KeyVersionState::Ended => {
                    ended.insert(scope, row.epoch);
                }
            }
        }
        drop(txn);
        // A key state that could not be read, as with a locked device store, keeps the lock the hooks hold.
        let lock = match &state {
            Ok(KeyState::Locked { cause }) => Some(*cause),
            Ok(_) => None,
            Err(_) => self.hooks.locked(),
        };
        self.hooks.refresh(lock, stopped, ended);
        ctx.locked = self.hooks.locked().is_some();
        ctx.keys_ready = !ctx.locked && matches!(state, Ok(KeyState::Approved { .. }));
        Ok(())
    }

    async fn push_rounds(&self, ctx: &mut PassCtx, session: &mut Session, info: &ScopeInfo) -> Result<(), SyncError> {
        if ctx.report.skipped.iter().any(|(scope, _)| *scope == info.scope) {
            return Ok(());
        }
        let mut info = info.clone();
        for _ in 0..ROUNDS {
            let after = match self.push_scope(ctx, &info).await {
                Err(error) => match scope_refusal(&error) {
                    Some(code) => {
                        ctx.report.skipped.push((info.scope, code));
                        return Ok(());
                    }
                    None => return Err(error),
                },
                Ok(after) => after,
            };
            match after {
                AfterPush::Done => return Ok(()),
                AfterPush::Pull => {}
                AfterPush::NewEpoch => {
                    ctx.body = self.poll_scopes(session).await?;
                    let Some(fresh) = ctx.body.scopes.iter().find(|held| held.scope == info.scope) else {
                        return Ok(());
                    };
                    info = fresh.clone();
                }
            }
            self.pull_or_skip(ctx, session, &info).await?;
            self.push_back(ctx).await?;
        }
        Ok(())
    }

    // Personal and history calls need this device's key, and nothing personal syncs on a locked device. The history
    // scope takes no call before approval (0051, Whole-request refusals).
    fn reachable(&self, ctx: &PassCtx) -> Vec<ScopeInfo> {
        let locked = ctx.locked;
        ctx.body
            .scopes
            .iter()
            .filter(|info| match info.scope {
                ScopeName::Team(_) => true,
                ScopeName::Personal => ctx.keyed && !locked,
                ScopeName::History => ctx.keyed && !locked && info.approved == Some(true),
            })
            .cloned()
            .collect()
    }

    // Each store's identity against what the state saw (0054, Store identity; 0060). A new generation or a lower
    // sequence, or a store the state never saw, as on the first pass or after a stale file, owes each of its kinds a
    // refill in `stores_kinds`, in the commit that moves its row (0066, Per-kind refills). A kind takes it once its
    // category is on, so a pass cut short, or a kind that is off, refills later.
    async fn read_stores(&self, ctx: &mut PassCtx, scopes: &[ScopeInfo]) -> Result<(), SyncError> {
        let mut kinds: HashMap<String, BTreeSet<Kind>> = HashMap::new();
        for info in scopes {
            for adapter in self.adapters.in_scope(info.scope) {
                kinds
                    .entry(adapter.store().to_owned())
                    .or_default()
                    .insert(adapter.kind());
            }
        }
        for info in scopes {
            for adapter in self.adapters.in_scope(info.scope) {
                let store = adapter.store().to_owned();
                if let Some(seen) = ctx.stores.get_mut(&store) {
                    seen.scopes.insert(info.scope);
                    continue;
                }
                let start = adapter.identity().await?;
                let mut txn = begin(&self.state).await?;
                let stored = match txn.get(&RowKey::Store(store.clone())).await? {
                    Some(Row::Store(row)) => Some(StoreStamp {
                        generation: row.generation,
                        sequence: row.sequence,
                    }),
                    _ => None,
                };
                let marked = stored.is_none_or(|stored| start.needs_refill(stored));
                if marked {
                    for kind in kinds.get(&store).into_iter().flatten() {
                        txn.put(Row::StoresKind(StoresKindRow {
                            store: store.clone(),
                            kind: KindName::of(*kind),
                        }))
                        .await?;
                    }
                    txn.put(Row::Store(StoreRow {
                        store: store.clone(),
                        generation: start.generation,
                        sequence: start.sequence,
                    }))
                    .await?;
                    self.stop.check()?;
                    txn.commit().await?;
                    txn = begin(&self.state).await?;
                }
                let owed = txn
                    .scan(&RowRange::Table(Table::StoresKinds))
                    .await?
                    .into_iter()
                    .filter_map(|row| match row {
                        Row::StoresKind(row) if row.store == store => row.kind.known(),
                        _ => None,
                    })
                    .collect();
                drop(txn);
                // The row this pass wrote, or the one the state held, so a store that moved on since gets its row.
                let seen = StoreSeen {
                    start,
                    stored: if marked { Some(start) } else { stored },
                    owed,
                    marked,
                    scopes: HashSet::from([info.scope]),
                };
                ctx.stores.insert(store, seen);
            }
        }
        Ok(())
    }

    // A store that went on has its newer sequence kept; the kinds it still owes a refill keep their marks.
    async fn write_stores(&self, ctx: &PassCtx) -> Result<(), SyncError> {
        let mut rows = Vec::new();
        for (store, seen) in &ctx.stores {
            if let Some(row) = self.store_row(store, seen).await? {
                rows.push(row);
            }
        }
        if rows.is_empty() {
            return Ok(());
        }
        self.stop.check()?;
        let mut txn = begin(&self.state).await?;
        for row in rows {
            txn.put(row).await?;
        }
        txn.commit().await?;
        Ok(())
    }

    // The store's identity now, unless it is the one the state holds or the store was replaced during the pass.
    async fn store_row(&self, store: &str, seen: &StoreSeen) -> Result<Option<Row>, SyncError> {
        let adapter = seen
            .scopes
            .iter()
            .flat_map(|scope| self.adapters.in_scope(*scope))
            .find(|adapter| adapter.store() == store);
        let Some(adapter) = adapter else {
            return Ok(None);
        };
        let now = adapter.identity().await?;
        let went_on = now.generation == seen.start.generation && now.sequence >= seen.start.sequence;
        Ok((went_on && seen.stored != Some(now)).then(|| {
            Row::Store(StoreRow {
                store: store.to_owned(),
                generation: now.generation,
                sequence: now.sequence,
            })
        }))
    }

    // The refills `scope`'s snapshot ends: each owed kind whose category is on and whose every scope has its snapshot
    // once `scope`'s is done, of a store not replaced during the pass, clears its mark in that commit. `except` waits,
    // and a kind that is off keeps its mark until it is on (0066, Per-kind refills).
    async fn settled_refills(
        &self,
        ctx: &mut PassCtx,
        scope: ScopeName,
        except: Option<&str>,
    ) -> Result<Vec<RowKey>, SyncError> {
        let done = |held: &ScopeName| *held == scope || ctx.snapshots_done.contains(held);
        let mut settling: Vec<(String, Kind)> = Vec::new();
        for (store, seen) in ctx.stores.iter().filter(|(store, _)| except != Some(store.as_str())) {
            for kind in seen.owed.iter().filter(|kind| ctx.categories.syncs(**kind)) {
                let scopes: Vec<ScopeName> = seen
                    .scopes
                    .iter()
                    .copied()
                    .filter(|held| {
                        self.adapters
                            .in_scope(*held)
                            .iter()
                            .any(|adapter| adapter.store() == store && adapter.kind() == *kind)
                    })
                    .collect();
                if scopes.contains(&scope) && scopes.iter().all(done) {
                    settling.push((store.clone(), *kind));
                }
            }
        }
        let mut cleared = Vec::new();
        for (store, kind) in settling {
            let Some(seen) = ctx.stores.get(&store) else {
                continue;
            };
            if !self.went_on(&store, seen).await? {
                continue;
            }
            if let Some(seen) = ctx.stores.get_mut(&store) {
                seen.owed.remove(&kind);
            }
            cleared.push(RowKey::StoresKind(store, KindName::of(kind)));
        }
        Ok(cleared)
    }

    // The store kept its generation and moved only forward since the pass began.
    async fn went_on(&self, store: &str, seen: &StoreSeen) -> Result<bool, SyncError> {
        let adapter = seen
            .scopes
            .iter()
            .flat_map(|scope| self.adapters.in_scope(*scope))
            .find(|adapter| adapter.store() == store);
        let Some(adapter) = adapter else {
            return Ok(false);
        };
        let now = adapter.identity().await?;
        Ok(now.generation == seen.start.generation && now.sequence >= seen.start.sequence)
    }

    // A restored, replaced or uncertain state file trusts none of its sync tables: every store refills, so the pull
    // wins and what the provider never saw goes up as creates (0054, A stale file).
    async fn refill_stale_file(&self, session: &mut Session) -> Result<(), SyncError> {
        if session.stale_handled {
            return Ok(());
        }
        if self.state.opened().sync_tables == crate::api::state::SyncTrust::Refill {
            self.stop.check()?;
            let mut txn = begin(&self.state).await?;
            for row in txn.scan(&RowRange::Table(Table::Stores)).await? {
                txn.delete(&row.key()).await?;
            }
            txn.commit().await?;
        }
        session.stale_handled = true;
        Ok(())
    }

    // A journal pass diffs only what it was told of, so the count it saw is not what waits.
    async fn finish(&self, outcome: &Result<PassReport, SyncError>, journal_only: bool) {
        let counts = self.counts().await;
        let mut status = self.status_lock();
        status.last_pass_ms = Some(self.clock.now_ms());
        match outcome {
            Ok(report) => {
                status.problem = None;
                if !journal_only {
                    status.queued_changes = u32::try_from(report.queued).unwrap_or(u32::MAX);
                }
                status.phase = if report.push_wait.is_some() {
                    SyncPhase::NewIdentity
                } else if report.pull_only {
                    SyncPhase::PullOnly
                } else {
                    SyncPhase::Idle
                };
            }
            Err(error) => {
                status.problem = Some(error.code());
                status.phase = if self.stop.is_stopped() {
                    SyncPhase::Off
                } else {
                    SyncPhase::Idle
                };
            }
        }
        if let Ok((held, conflicts, approvals)) = counts {
            status.held = held;
            status.conflicts = conflicts;
            status.waiting_approvals = approvals;
        }
        drop(status);
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }

    async fn counts(&self) -> Result<(u32, u32, u32), SyncError> {
        let mut txn = begin(&self.state).await?;
        let held = txn.scan(&RowRange::Table(Table::Held)).await?.len();
        let conflicts = txn.scan(&RowRange::Table(Table::Conflicts)).await?.len();
        drop(txn);
        let approvals = self.queue().count().await?;
        Ok((
            u32::try_from(held).unwrap_or(u32::MAX),
            u32::try_from(conflicts).unwrap_or(u32::MAX),
            approvals,
        ))
    }

    async fn refresh_counts(&self) {
        if let Ok((held, conflicts, approvals)) = self.counts().await {
            let mut status = self.status_lock();
            status.held = held;
            status.conflicts = conflicts;
            status.waiting_approvals = approvals;
        }
    }
}

#[async_trait]
impl Pass for ServiceSync {
    async fn pass(&self, why: PassReason) -> Result<(), SyncError> {
        self.run_pass(why).await.map(|_| ())
    }

    fn poll_interval(&self) -> Duration {
        let secs = self
            .session
            .try_lock()
            .ok()
            .and_then(|session| session.body.as_ref().map(|body| body.poll_interval_secs))
            .unwrap_or(60);
        Duration::from_secs(secs.max(1))
    }

    fn waiting(&self, retry_in_ms: Option<u64>) {
        let phase = retry_in_ms.map_or(SyncPhase::Idle, |retry_in_ms| SyncPhase::Waiting { retry_in_ms });
        self.set_phase(phase);
    }
}

#[async_trait]
impl SyncControl for ServiceSync {
    fn status(&self) -> SyncStatus {
        self.status_lock().clone()
    }

    async fn sync_now(&self, why: PassReason) -> Result<(), SyncError> {
        self.run_pass(why).await.map(|_| ())
    }

    // An off kind sends nothing and takes nothing; turning one on reads it again (0054, Rules for both providers).
    async fn set_categories(&self, categories: SyncCategories) -> Result<(), SyncError> {
        let categories = DeviceCategories::from(&categories);
        let changed = {
            let mut held = self.categories.lock().unwrap_or_else(PoisonError::into_inner);
            let changed = *held != categories;
            *held = categories;
            changed
        };
        if changed {
            self.journal.pass_soon(PassReason::Person);
        }
        Ok(())
    }

    // A store the app still keeps tells what its write changed, as a core store's journal does (0060).
    async fn host_changed(&self, kind: KindName, written: Vec<String>, deleted: Vec<String>) -> Result<(), SyncError> {
        let Some(kind) = kind.known() else {
            return Err(SyncError::Unknown { what: "kind" });
        };
        self.journal.changed(&[JournalEntry { kind, written, deleted }]);
        Ok(())
    }

    async fn approvals(&self) -> Result<Vec<PendingApproval>, SyncError> {
        let _session = self.session.lock().await;
        self.queue().waiting().await
    }

    async fn plan_new_identity(&self) -> Result<NewIdentityPlan, SyncError> {
        let _session = self.session.lock().await;
        self.plan_choice().await
    }

    async fn choose_for_new_identity(&self, choice: NewIdentityChoice, account: String) -> Result<(), SyncError> {
        self.answer_choice(choice, &account).await
    }

    async fn decide_approval(
        &self,
        key: RecordKey,
        field: String,
        seen: [u8; 32],
        approve: bool,
    ) -> Result<(), SyncError> {
        let session = self.session.lock().await;
        self.queue().decide(&key, &field, seen, approve).await?;
        drop(session);
        self.refresh_counts().await;
        self.decided(&key);
        Ok(())
    }

    async fn conflicts(&self) -> Result<Vec<TeamConflict>, SyncError> {
        let _session = self.session.lock().await;
        self.conflict_table().open().await
    }

    async fn resolve_conflict(&self, key: RecordKey, seen: [u8; 32], keep: ConflictChoice) -> Result<(), SyncError> {
        let session = self.session.lock().await;
        self.conflict_table().resolve(&key, seen, keep).await?;
        drop(session);
        self.refresh_counts().await;
        self.decided(&key);
        Ok(())
    }

    async fn load_older_history(&self) -> Result<bool, SyncError> {
        let _session = self.session.lock().await;
        self.load_older().await
    }

    async fn held_records(&self) -> Result<Vec<HeldRecord>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let mut held: Vec<HeldRecord> = txn
            .scan(&RowRange::Table(Table::Held))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(row) => Some(HeldRecord {
                    key: row.key,
                    reason: HeldRecordReason::Held(row.reason),
                }),
                _ => None,
            })
            .collect();
        held.extend(
            txn.scan(&RowRange::Table(Table::Refused))
                .await?
                .into_iter()
                .filter_map(|row| match row {
                    Row::Refused(row) => Some(HeldRecord {
                        key: row.key,
                        reason: HeldRecordReason::Refused { code: row.code },
                    }),
                    _ => None,
                }),
        );
        Ok(held)
    }
}
