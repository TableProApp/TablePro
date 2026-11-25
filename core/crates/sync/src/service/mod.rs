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

use crate::api::adapter::StoreStamp;
use crate::api::control::{HeldRecord, HeldRecordReason, PassReason, SyncControl, SyncPhase, SyncStatus};
use crate::api::error::SyncError;
use crate::api::ids::{RecordKey, ScopeName};
use crate::api::key_flows::{KeyFlows, LockCause};
use crate::api::scopes::{ScopeInfo, ScopesBody};
use crate::api::state::{Provider, Row, RowKey, RowRange, StateStore, StateTxn, Table};
use crate::api::transport::{DpopKey, ServiceTransport, TransportError};
use crate::engine::{AdapterSet, Clock, EngineEvents, EngineHooks, Pass, StopSignal};

// This device's signing key, which every personal and history call and every key-object or envelope write carries
// (0051, DPoP). None until the device holds keys.
#[async_trait]
pub trait ProofSource: Send + Sync {
    async fn dpop_key(&self) -> Result<Option<DpopKey>, SyncError>;
}

pub struct ServiceParts {
    pub transport: Arc<dyn ServiceTransport>,
    pub state: Arc<dyn StateStore>,
    pub adapters: Arc<dyn AdapterSet>,
    pub keys: Arc<dyn KeyFlows>,
    pub hooks: Arc<EngineHooks>,
    pub proofs: Arc<dyn ProofSource>,
    pub clock: Arc<dyn Clock>,
    pub stop: StopSignal,
    pub events: Option<Arc<dyn EngineEvents>>,
}

pub struct ServiceSync {
    transport: Arc<dyn ServiceTransport>,
    state: Arc<dyn StateStore>,
    adapters: Arc<dyn AdapterSet>,
    keys: Arc<dyn KeyFlows>,
    hooks: Arc<EngineHooks>,
    proofs: Arc<dyn ProofSource>,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
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
    key: Option<DpopKey>,
    stores: HashMap<String, StoreSeen>,
    snapshots_done: HashSet<ScopeName>,
    new_epoch: bool,
    pushed_back: bool,
    report: PassReport,
}

impl PassCtx {
    fn refills(&self, store: &str) -> bool {
        self.stores.get(store).is_some_and(|seen| seen.refill)
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
        let outcome = self.run(&mut session).await;
        if let Err(SyncError::Transport(TransportError::DeviceRemoved)) = &outcome {
            crate::api::key_flows::KeyHooks::lock(self.hooks.as_ref(), LockCause::DeviceRemoved);
        }
        self.finish(&outcome).await;
        outcome
    }

    async fn run(&self, session: &mut Session) -> Result<PassReport, SyncError> {
        self.stop.check()?;
        self.refill_stale_file(session).await?;
        let body = self.poll_scopes(session).await?;
        let key = self.proofs.dpop_key().await?;
        let mut ctx = PassCtx {
            body,
            key,
            stores: HashMap::new(),
            snapshots_done: HashSet::new(),
            new_epoch: false,
            pushed_back: false,
            report: PassReport::default(),
        };
        let scopes = self.reachable(&ctx);
        self.read_stores(&mut ctx, &scopes).await?;
        for info in &scopes {
            self.pull_or_skip(&mut ctx, info).await?;
        }
        self.push_back(&mut ctx).await?;
        self.resume_flows().await;
        for info in &scopes {
            self.push_rounds(&mut ctx, session, info).await?;
        }
        self.write_stores(&ctx).await?;
        self.stop_actions(&ctx).await?;
        Ok(ctx.report)
    }

    async fn pull_or_skip(&self, ctx: &mut PassCtx, info: &ScopeInfo) -> Result<(), SyncError> {
        match self.pull_scope(ctx, info).await {
            Err(SyncError::Transport(
                error @ (TransportError::SeatRequired | TransportError::NotFound | TransportError::DeviceNotApproved),
            )) => {
                ctx.report.skipped.push((info.scope, error.code()));
                Ok(())
            }
            other => other,
        }
    }

    async fn push_rounds(&self, ctx: &mut PassCtx, session: &mut Session, info: &ScopeInfo) -> Result<(), SyncError> {
        if ctx.report.skipped.iter().any(|(scope, _)| *scope == info.scope) {
            return Ok(());
        }
        let mut info = info.clone();
        for _ in 0..ROUNDS {
            match self.push_scope(ctx, session, &info).await? {
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
            self.pull_or_skip(ctx, &info).await?;
            self.push_back(ctx).await?;
        }
        Ok(())
    }

    // Personal and history calls need this device's key, and nothing personal syncs on a locked device. The history
    // scope takes no call before approval (0051, Whole-request refusals).
    fn reachable(&self, ctx: &PassCtx) -> Vec<ScopeInfo> {
        let locked = self.hooks.locked().is_some();
        ctx.body
            .scopes
            .iter()
            .filter(|info| match info.scope {
                ScopeName::Team(_) => true,
                ScopeName::Personal => ctx.key.is_some() && !locked,
                ScopeName::History => ctx.key.is_some() && !locked && info.approved == Some(true),
            })
            .cloned()
            .collect()
    }

    // Each store's identity against what the state saw (0054, Store identity; 0060). One the state never saw, as on
    // the first pass or after a stale file, refills too.
    async fn read_stores(&self, ctx: &mut PassCtx, scopes: &[ScopeInfo]) -> Result<(), SyncError> {
        for info in scopes {
            for adapter in self.adapters.adapters(info.scope) {
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
                let seen = StoreSeen {
                    start,
                    stored,
                    refill: stored.is_none_or(|stored| start.needs_refill(stored)),
                    scopes: HashSet::from([info.scope]),
                };
                ctx.stores.insert(store, seen);
            }
        }
        Ok(())
    }

    // A store's identity goes into the state once its kinds are settled: a refilled store only when every scope that
    // holds it finished its snapshot, and never when the store was replaced during the pass.
    async fn write_stores(&self, ctx: &PassCtx) -> Result<(), SyncError> {
        let mut rows = Vec::new();
        for (store, seen) in &ctx.stores {
            if seen.refill && !seen.scopes.iter().all(|scope| ctx.snapshots_done.contains(scope)) {
                continue;
            }
            let adapter = seen
                .scopes
                .iter()
                .flat_map(|scope| self.adapters.adapters(*scope))
                .find(|adapter| adapter.store() == store);
            let Some(adapter) = adapter else { continue };
            let now = adapter.identity().await?;
            let unchanged = seen.stored == Some(now);
            if !unchanged && now.generation == seen.start.generation && now.sequence >= seen.start.sequence {
                rows.push(Row::Store(crate::api::state::StoreRow {
                    store: store.clone(),
                    generation: now.generation,
                    sequence: now.sequence,
                }));
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

    async fn finish(&self, outcome: &Result<PassReport, SyncError>) {
        let counts = self.counts().await;
        let mut status = self.status_lock();
        status.last_pass_ms = Some(self.clock.now_ms());
        match outcome {
            Ok(report) => {
                status.problem = None;
                status.queued_changes = u32::try_from(report.queued).unwrap_or(u32::MAX);
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
