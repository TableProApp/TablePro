// The TablePro Sync pass (0051, Protocol; Restore; 0054, The engine): the scopes body, then each scope's pull, the key
// objects a new epoch needs pushed back, the flows to resume, each scope's push with its outbox, and the stop reports.

mod keys;
mod pull;
mod push;
mod refill;
mod scopes;

use push::AfterPush;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_keys::encoding::KeyPurpose;

use crate::api::adapter::StoreStamp;
use crate::api::control::{HeldRecord, HeldRecordReason, PassReason, SyncControl, SyncPhase, SyncStatus};
use crate::api::device_store::DeviceStoreError;
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, RecordKey, ScopeName};
use crate::api::key_flows::{KeyFlows, KeyState, LockCause};
use crate::api::scopes::{LineageEpoch, ScopeInfo, ScopesBody};
use crate::api::state::{
    KeyVersionState, Provider, Row, RowKey, RowRange, StateStore, StateTxn, StoppedCause, StoreRow, Table,
};
use crate::api::transport::{DpopKey, ServiceTransport, TransportError};
use crate::engine::{Adapters, Clock, EngineEvents, EngineHooks, Journal, JournalIds, Pass, StopSignal};
use crate::keys::KeyService;

// This device's signing key, which every personal and history call and every key-object or envelope write carries
// (0051, DPoP). None until the device holds keys.
#[async_trait]
pub trait ProofSource: Send + Sync {
    async fn dpop_key(&self) -> Result<Option<DpopKey>, SyncError>;
}

// The device keys are made on the first call, since a device proves even its first pull and its genesis or first
// request certifies them (0056, Approving a device, step 1). With no device store there is no key to prove with, and
// only team plaintext syncs.
#[async_trait]
impl ProofSource for KeyService {
    async fn dpop_key(&self) -> Result<Option<DpopKey>, SyncError> {
        match self.ensure_device_keys().await {
            Ok(device) => Ok(Some(DpopKey(Arc::new(device.dsk)))),
            Err(SyncError::DeviceStore(DeviceStoreError::Unavailable { .. })) => Ok(None),
            Err(error) => Err(error),
        }
    }
}

pub struct ServiceParts {
    pub transport: Arc<dyn ServiceTransport>,
    pub state: Arc<dyn StateStore>,
    pub adapters: Adapters,
    pub keys: Arc<dyn KeyFlows>,
    pub hooks: Arc<EngineHooks>,
    pub proofs: Arc<dyn ProofSource>,
    pub clock: Arc<dyn Clock>,
    pub stop: StopSignal,
    pub journal: Journal,
    pub events: Option<Arc<dyn EngineEvents>>,
}

pub struct ServiceSync {
    transport: Arc<dyn ServiceTransport>,
    state: Arc<dyn StateStore>,
    adapters: Adapters,
    keys: Arc<dyn KeyFlows>,
    hooks: Arc<EngineHooks>,
    proofs: Arc<dyn ProofSource>,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
    journal: Journal,
    events: Option<Arc<dyn EngineEvents>>,
    // One pass at a time per state file (0054, Scheduling).
    session: tokio::sync::Mutex<Session>,
    status: Mutex<SyncStatus>,
}

#[derive(Debug, Default)]
struct Session {
    etag: Option<String>,
    body: Option<ScopesBody>,
    // Changes the server refused, by what they would send, so a pass does not send them again until they change.
    refused: HashMap<RecordKey, ([u8; 32], String)>,
    stale_handled: bool,
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
}

// One store as the pass found it: its identity at the start, and whether its kinds refill.
#[derive(Debug, Clone)]
struct StoreSeen {
    start: StoreStamp,
    stored: Option<StoreStamp>,
    refill: bool,
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
    report: PassReport,
}

impl PassCtx {
    fn refills(&self, store: &str) -> bool {
        self.stores.get(store).is_some_and(|seen| seen.refill)
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
            proofs: parts.proofs,
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
        let body = self.poll_scopes(session).await?;
        let keyed = self.proofs.dpop_key().await?.is_some();
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
        let mut pulled = self.pull_scope(ctx, info).await;
        if let Err(SyncError::Transport(TransportError::CursorExpired)) = pulled {
            ctx.body = self.poll_scopes(session).await?;
            let Some(fresh) = ctx.body.scopes.iter().find(|held| held.scope == info.scope).cloned() else {
                return Ok(());
            };
            pulled = self.pull_scope(ctx, &fresh).await;
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
            let after = match self.push_scope(ctx, session, &info).await {
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

    // Each store's identity against what the state saw (0054, Store identity; 0060). One the state never saw, as on
    // the first pass or after a stale file, refills too.
    async fn read_stores(&self, ctx: &mut PassCtx, scopes: &[ScopeInfo]) -> Result<(), SyncError> {
        for info in scopes {
            for adapter in self.adapters.in_scope(info.scope) {
                let store = adapter.store().to_owned();
                if let Some(seen) = ctx.stores.get_mut(&store) {
                    seen.scopes.insert(info.scope);
                    continue;
                }
                let start = adapter.identity().await?;
                let stored = match begin(&self.state).await?.get(&RowKey::Store(store.clone())).await? {
                    Some(Row::Store(row)) => Some(StoreStamp {
                        generation: row.generation,
                        sequence: row.sequence,
                    }),
                    _ => None,
                };
                let refill = stored.is_none_or(|stored| start.needs_refill(stored));
                // Kept as a missing row until the refill is done, so a pass cut short refills again and the writes
                // of a half-done refill never read as the store going on.
                if refill && stored.is_some() {
                    self.stop.check()?;
                    let mut txn = begin(&self.state).await?;
                    txn.delete(&RowKey::Store(store.clone())).await?;
                    txn.commit().await?;
                }
                let seen = StoreSeen {
                    start,
                    stored: stored.filter(|_| !refill),
                    refill,
                    scopes: HashSet::from([info.scope]),
                };
                ctx.stores.insert(store, seen);
            }
        }
        Ok(())
    }

    // A store that went on has its newer sequence kept. A refilling store's row goes in with its last snapshot.
    async fn write_stores(&self, ctx: &PassCtx) -> Result<(), SyncError> {
        let mut rows = Vec::new();
        for (store, seen) in &ctx.stores {
            if seen.refill {
                continue;
            }
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

    // The refilling stores whose every scope has its snapshot once `scope`'s is done, which settle in that commit;
    // `except` waits.
    async fn settled_stores(
        &self,
        ctx: &mut PassCtx,
        scope: ScopeName,
        except: Option<&str>,
    ) -> Result<Vec<Row>, SyncError> {
        let mut rows = Vec::new();
        let done = |held: &ScopeName| *held == scope || ctx.snapshots_done.contains(held);
        let settling: Vec<String> = ctx
            .stores
            .iter()
            .filter(|(store, _)| except != Some(store.as_str()))
            .filter(|(_, seen)| seen.refill && seen.scopes.contains(&scope) && seen.scopes.iter().all(done))
            .map(|(store, _)| store.clone())
            .collect();
        for store in settling {
            let Some(seen) = ctx.stores.get_mut(&store) else {
                continue;
            };
            if let Some(Row::Store(row)) = self.store_row(&store, seen).await? {
                seen.refill = false;
                seen.stored = Some(StoreStamp {
                    generation: row.generation,
                    sequence: row.sequence,
                });
                rows.push(Row::Store(row));
            }
        }
        Ok(rows)
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
                status.phase = if report.pull_only {
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
        if let Ok((held, conflicts)) = counts {
            status.held = held;
            status.conflicts = conflicts;
        }
        drop(status);
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }

    async fn counts(&self) -> Result<(u32, u32), SyncError> {
        let mut txn = begin(&self.state).await?;
        let held = txn.scan(&RowRange::Table(Table::Held)).await?.len();
        let conflicts = txn.scan(&RowRange::Table(Table::Conflicts)).await?.len();
        Ok((
            u32::try_from(held).unwrap_or(u32::MAX),
            u32::try_from(conflicts).unwrap_or(u32::MAX),
        ))
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
        drop(txn);
        let session = self.session.lock().await;
        held.extend(session.refused.iter().map(|(key, (_, code))| HeldRecord {
            key: key.clone(),
            reason: HeldRecordReason::Refused { code: code.clone() },
        }));
        Ok(held)
    }
}
