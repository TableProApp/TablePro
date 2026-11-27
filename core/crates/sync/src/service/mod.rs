// The TablePro Sync pass (0051, Protocol; Restore; 0054, The engine): the scopes body, then each scope's pull, the key
// objects a new epoch needs pushed back, the flows to resume, each scope's push with its outbox, and the stop reports.

mod identity;
mod keys;
mod pull;
mod push;
mod refill;
mod scopes;
mod team_library;

pub use identity::unsent_changes;
use push::AfterPush;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
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
    ConflictChoice, HeldRecord, HeldRecordReason, MovePlan, NewIdentityChoice, NewIdentityPlan, PassReason,
    PendingApproval, SyncCategories, SyncControl, SyncPhase, SyncStatus, TeamConflict,
};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, KindName, RecordKey, ScopeName};
use crate::api::key_flows::{KeyFlows, KeyState, LockCause};
use crate::api::scopes::{LineageEpoch, ScopeInfo, ScopesBody};
use crate::api::state::{
    ApprovalDecision, KeyVersionState, MovePhase, MoveRow, Provider, Row, RowKey, RowRange, Standing, StateIdentity,
    StateStore, StateTxn, StoppedCause, StoreRow, StoresKindRow, Table,
};
use crate::api::transport::{ServiceTransport, TransportError};
use crate::engine::{
    Adapters, Clock, EngineEvents, EngineHooks, Fence, Journal, JournalEntry, JournalIds, Pass, StopSignal,
};
use crate::moves::{Arrival, MoveFence};

// What the service carries for this device (0054, Providers). Team scopes always use it, and so do the key objects in
// the personal scope, since team secrets need the account keys; personal data only while it is the personal provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum ServiceMode {
    #[default]
    Personal,
    // The personal provider is iCloud or Off: personal data rests here as if every category were off, so turning
    // personal sync on later reads it again against the copies last agreed, and the history scope is not reached.
    TeamsOnly,
}

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
    // Known before the first pass, so no pass of a device on iCloud or Off ever carries personal data.
    pub mode: ServiceMode,
    // This account follows another account or server on this device: the changes the last one's file held unsent,
    // which the opener counts with `unsent_changes`. Nothing personal goes up until the person chooses (0054,
    // Another account or server).
    pub follows: Option<u64>,
}

pub struct ServiceSync {
    transport: Arc<dyn ServiceTransport>,
    state: Arc<dyn StateStore>,
    adapters: Adapters,
    team_adapters: Adapters,
    keys: Arc<dyn KeyFlows>,
    hooks: Arc<EngineHooks>,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
    // Switches to teams-only still waiting for the session: while one waits, the pass in flight ends at its next store
    // write, commit or send, and so does any pass queued before it, so nothing personal goes on once personal sync
    // stops (0055, Leaving a provider). A count, so no other switch can lift it.
    leaving: AtomicUsize,
    journal: Journal,
    events: Option<Arc<dyn EngineEvents>>,
    // Changed only under the session lock, so one pass and one decision each see one mode.
    mode: Mutex<ServiceMode>,
    // What the last full pass found to send, per scope, so the count shown leaves out the scopes that rest.
    queued: Mutex<HashMap<ScopeName, usize>>,
    // The managed values forbid personal data on TablePro Sync for this engine's life.
    policy_forbids: std::sync::atomic::AtomicBool,
    // A restored or replaced file's move row was dropped, so the rows this engine writes since are its own.
    stale_move_dropped: std::sync::atomic::AtomicBool,
    // The person chose for the account this engine follows another one with.
    chosen: std::sync::atomic::AtomicBool,
    // One pass at a time per state file (0054, Scheduling).
    session: tokio::sync::Mutex<Session>,
    status: Mutex<SyncStatus>,
    categories: Mutex<DeviceCategories>,
    // The history entries this device keeps, its retention, which a snapshot takes newest first; None takes all.
    history_window: Mutex<Option<u32>>,
    // The scopes as the last body served them, which the app reads while a pass holds the session.
    scopes_seen: Mutex<Vec<ScopeInfo>>,
    follows: Option<u64>,
    team_library: team_library::TeamLibrarySlot,
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
    // The scopes this pass reached, as the device's keys and lock let it.
    pub reached: Vec<ScopeName>,
    // Pulled records the store refused to keep, held by id.
    pub store_refused: Vec<RecordKey>,
    pub skipped: Vec<(ScopeName, &'static str)>,
    pub pull_only: bool,
    pub queued: usize,
    pub queued_in: HashMap<ScopeName, usize>,
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
    mode: ServiceMode,
    // Personal data arriving this pass, and by which rule its snapshot meets the device's records.
    arrival: Option<Arc<Arrival>>,
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

    // What a scope takes and sends this pass: in teams-only mode the personal scope keeps to its key objects.
    fn categories_in(&self, scope: ScopeName) -> DeviceCategories {
        if carries_personal(self.mode, scope) {
            self.categories.clone()
        } else {
            DeviceCategories::keys_only()
        }
    }
}

// Whether the mode carries the records of `scope`, the key objects aside.
const fn carries_personal(mode: ServiceMode, scope: ScopeName) -> bool {
    matches!(mode, ServiceMode::Personal) || matches!(scope, ScopeName::Team(_))
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

// The stores whose records another store held before: the saved queries, their folders and favourites split out of
// the history's file (K4h).
const SPLIT_FROM: [(&str, &str); 1] = [(
    crate::adapters::saved_queries::SAVED_QUERY_STORE,
    crate::adapters::history::HISTORY_STORE,
)];

// A store this file never saw, split out of one the file did see: its kinds keep their bases and merge as before, so
// an edit made offline before the split still goes up, and a refill the old store's name still owed moves with it
// (K4h; Codex review round 2). A file that never saw the old store either, as a new or stale one, refills as usual.
async fn carried_over(
    txn: &mut dyn StateTxn,
    store: &str,
    kind: Kind,
    known: &HashSet<String>,
) -> Result<bool, SyncError> {
    let Some((_, old)) = SPLIT_FROM.iter().find(|(new, _)| *new == store) else {
        return Ok(false);
    };
    if !known.contains(*old) {
        return Ok(false);
    }
    let name = KindName::of(kind);
    if txn
        .get(&RowKey::StoresKind((*old).to_owned(), name.clone()))
        .await?
        .is_some()
    {
        txn.delete(&RowKey::StoresKind((*old).to_owned(), name.clone())).await?;
        txn.put(Row::StoresKind(StoresKindRow {
            store: store.to_owned(),
            kind: name,
        }))
        .await?;
    }
    Ok(true)
}

impl ServiceSync {
    pub fn new(parts: ServiceParts) -> Self {
        Self {
            transport: parts.transport,
            state: parts.state,
            team_adapters: parts.adapters.teams_only(),
            adapters: parts.adapters,
            keys: parts.keys,
            hooks: parts.hooks,
            clock: parts.clock,
            stop: parts.stop,
            leaving: AtomicUsize::new(0),
            journal: parts.journal,
            events: parts.events,
            mode: Mutex::new(parts.mode),
            queued: Mutex::default(),
            policy_forbids: std::sync::atomic::AtomicBool::new(false),
            stale_move_dropped: std::sync::atomic::AtomicBool::new(false),
            chosen: std::sync::atomic::AtomicBool::new(false),
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
            scopes_seen: Mutex::new(Vec::new()),
            follows: parts.follows,
            team_library: team_library::TeamLibrarySlot::default(),
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
    // Each scope as the last scopes body served it: its policies, whether it takes writes, its role (0051, Scopes;
    // Policies). Empty before the first poll.
    pub fn scopes_seen(&self) -> Vec<ScopeInfo> {
        self.scopes_seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    // A body that changed what the app shows of its scopes tells the app to read them again.
    fn saw_scopes(&self, body: &ScopesBody) {
        let changed = {
            let mut seen = self.scopes_seen.lock().unwrap_or_else(PoisonError::into_inner);
            let changed = *seen != body.scopes;
            seen.clone_from(&body.scopes);
            changed
        };
        if changed && let Some(events) = &self.events {
            events.status_changed();
        }
    }

    pub fn set_history_window(&self, entries: Option<u32>) {
        *self.history_window.lock().unwrap_or_else(PoisonError::into_inner) = entries;
    }

    // The sign-in this engine's state file belongs to.
    pub fn identity(&self) -> &StateIdentity {
        self.state.identity()
    }

    pub fn mode(&self) -> ServiceMode {
        *self.mode.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // Between passes: a move between providers, or the person turning personal sync on or off. Turning it on reads the
    // personal scope again on the next pass, since its kinds were off meanwhile.
    pub async fn set_mode(&self, mode: ServiceMode) {
        let mode = if self.policy_rests() {
            ServiceMode::TeamsOnly
        } else {
            mode
        };
        let leaving = mode == ServiceMode::TeamsOnly;
        if leaving {
            self.leaving.fetch_add(1, Ordering::SeqCst);
        }
        let session = self.session.lock().await;
        let changed = {
            let mut held = self.mode.lock().unwrap_or_else(PoisonError::into_inner);
            std::mem::replace(&mut *held, mode) != mode
        };
        if leaving {
            self.leaving.fetch_sub(1, Ordering::SeqCst);
        }
        drop(session);
        if changed {
            self.refresh_counts().await;
            let queued = self.queued_shown();
            self.status_lock().queued_changes = queued;
            if let Some(events) = &self.events {
                events.status_changed();
            }
            self.journal.pass_soon(PassReason::Person);
        }
    }

    fn check_stop(&self) -> Result<(), SyncError> {
        self.stop.check()?;
        if self.switching() || (self.policy_rests() && self.mode() == ServiceMode::Personal) {
            return Err(SyncError::Cancelled);
        }
        Ok(())
    }

    // The managed values forbid personal data on TablePro Sync (0055): it rests for this engine's life, and no move
    // or mode change brings it back, so a move in flight when they changed commits nothing more.
    pub fn forbid_personal(&self) {
        self.policy_forbids.store(true, Ordering::SeqCst);
    }

    fn policy_rests(&self) -> bool {
        self.policy_forbids.load(Ordering::SeqCst)
    }

    fn switching(&self) -> bool {
        self.leaving.load(Ordering::SeqCst) > 0
    }

    fn stopping(&self) -> bool {
        self.stop.is_stopped() || self.switching()
    }

    fn queued_shown(&self) -> u32 {
        let queued = self.queued.lock().unwrap_or_else(PoisonError::into_inner);
        let shown: usize = queued
            .iter()
            .filter(|(scope, _)| carries_personal(self.mode(), **scope))
            .map(|(_, count)| *count)
            .sum();
        u32::try_from(shown).unwrap_or(u32::MAX)
    }

    // The stores as the person's decisions reach them: a value the service pulled for personal data while it rests
    // stays out of them.
    fn decided_adapters(&self) -> &Adapters {
        match self.mode() {
            ServiceMode::Personal => &self.adapters,
            ServiceMode::TeamsOnly => &self.team_adapters,
        }
    }

    fn shows(&self, key: &RecordKey) -> bool {
        carries_personal(self.mode(), key.scope)
    }

    fn queue(&self) -> Queue<'_> {
        Queue {
            state: &self.state,
            adapters: self.decided_adapters(),
            fence: self,
        }
    }

    fn conflict_table(&self) -> Conflicts<'_> {
        Conflicts {
            state: &self.state,
            adapters: self.decided_adapters(),
            fence: self,
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
        self.pass_locked(&mut session, why, None).await
    }

    // Personal data arrives from another provider or from none (0054, Moving between providers): what the service file
    // kept of the personal scope while it rested is let go, its pull starts from a snapshot that meets the device's
    // records by `arrival`'s rule, and personal sync is on from then. One that fails leaves personal data resting. The
    // `moves` row holds the arrival open from the commit that lets go until the commit that ends it, so a move called
    // again after it stopped short, in this process or after a restart, goes on from the bases its first try committed
    // and a record merged then never meets the marker again.
    pub(crate) async fn run_arrival(&self, arrival: Arrival, fence: &MoveFence<'_>) -> Result<PassReport, SyncError> {
        let mut session = self.session.lock().await;
        self.check_stop()?;
        if self.policy_rests() {
            return Err(SyncError::NotAllowed {
                what: "personal data on TablePro Sync while the managed policy forbids it",
            });
        }
        let from = arrival.from();
        let open = matches!(
            self.move_row().await?,
            Some(MoveRow {
                target: Provider::Service,
                phase: MovePhase::Open,
                ..
            })
        );
        // A move back that went through rests personal data here; a new arrival starts over from it.
        if !open {
            self.let_go_of_personal(matches!(arrival, Arrival::FirstUpload), from, fence)
                .await?;
        }
        let before = std::mem::replace(
            &mut *self.mode.lock().unwrap_or_else(PoisonError::into_inner),
            ServiceMode::Personal,
        );
        let outcome = match self
            .pass_locked(&mut session, PassReason::Person, Some(Arc::new(arrival)))
            .await
        {
            Ok(report) => self.arrived(report, fence).await,
            Err(error) => Err(error),
        };
        if outcome.is_err() {
            *self.mode.lock().unwrap_or_else(PoisonError::into_inner) = before;
            self.refresh_counts().await;
        }
        outcome
    }

    // The personal scope was pulled to the end and nothing personal is left to send, so no record goes up later without
    // the rules of the move. The row then says done until the app keeps TablePro Sync as its provider, so a move that
    // went through while the app was not watching still tells it.
    async fn arrived(&self, report: PassReport, fence: &MoveFence<'_>) -> Result<PassReport, SyncError> {
        let personal = ScopeName::Personal;
        let reached = report.reached.contains(&personal)
            && !report.pull_only
            && !report.skipped.iter().any(|(scope, _)| *scope == personal)
            && self.scope_row(personal).await?.is_some_and(|row| row.caught_up);
        if !reached || self.unsent(personal).await? != 0 {
            return Err(SyncError::MoveIncomplete);
        }
        let from = self.move_row().await?.and_then(|row| row.from);
        let mut txn = begin(&self.state).await?;
        txn.put(Row::Move(MoveRow {
            from,
            target: Provider::Service,
            phase: MovePhase::Done,
        }))
        .await?;
        let _held = fence.hold().await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(report)
    }

    // The app keeps the move's target as its provider: the row has told it and goes.
    pub async fn clear_done_move(&self) -> Result<(), SyncError> {
        if self.move_row().await?.is_some_and(|row| row.phase == MovePhase::Done) {
            let mut txn = begin(&self.state).await?;
            txn.delete(&RowKey::Move).await?;
            txn.commit().await?;
        }
        Ok(())
    }

    // The move this file holds open or done, if any. A file restored or replaced under the device holds none it can
    // act on: an old row is no consent to move again, and the refill drops it.
    pub async fn move_row(&self) -> Result<Option<MoveRow>, SyncError> {
        if self.state.opened().sync_tables == crate::api::state::SyncTrust::Refill
            && !self.stale_move_dropped.swap(true, Ordering::SeqCst)
        {
            let mut txn = begin(&self.state).await?;
            txn.delete(&RowKey::Move).await?;
            txn.commit().await?;
        }
        Ok(match begin(&self.state).await?.get(&RowKey::Move).await? {
            Some(Row::Move(row)) => Some(row),
            _ => None,
        })
    }

    // A move back to iCloud starts: until it ends, personal data rests here as on iCloud, after a restart too.
    pub(crate) async fn leave_for_icloud(&self, fence: &MoveFence<'_>) -> Result<(), SyncError> {
        let mut txn = begin(&self.state).await?;
        txn.put(Row::Move(MoveRow {
            from: Some(Provider::Service),
            target: Provider::ICloud,
            phase: MovePhase::Open,
        }))
        .await?;
        let _held = fence.hold().await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    // The move back went through: iCloud holds the personal data, which stays resting here; the row says done until the
    // app keeps iCloud as its provider.
    pub(crate) async fn left_for_icloud(&self, fence: &MoveFence<'_>) -> Result<(), SyncError> {
        self.set_mode(ServiceMode::TeamsOnly).await;
        let mut txn = begin(&self.state).await?;
        txn.put(Row::Move(MoveRow {
            from: Some(Provider::Service),
            target: Provider::ICloud,
            phase: MovePhase::Done,
        }))
        .await?;
        let _held = fence.hold().await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    // Personal records the person deleted on the service that this device no longer holds: what a move back to iCloud
    // may delete there. A `policy` tombstone is not one (0051, Tombstones).
    pub(crate) async fn deleted_by_the_person(&self) -> Result<Vec<RecordKey>, SyncError> {
        let scope = ScopeName::Personal;
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Bases, scope))
            .await?;
        let held = self.personal_ids().await?;
        let mut deleted = Vec::new();
        for row in rows {
            let Row::Base(base) = row else { continue };
            let Some(kind) = base.key.kind.known() else { continue };
            if base.deleted != Some(crate::api::transport::DeletedReason::User) || kind.is_key() {
                continue;
            }
            if !held.get(&kind).is_some_and(|ids| ids.contains(&base.key.record_id)) {
                deleted.push(base.key);
            }
        }
        Ok(deleted)
    }

    // The ids each personal store holds, readable or not.
    pub(crate) async fn personal_ids(&self) -> Result<HashMap<Kind, HashSet<String>>, SyncError> {
        let scope = ScopeName::Personal;
        let mut held: HashMap<Kind, HashSet<String>> = HashMap::new();
        for adapter in self.adapters.in_scope(scope) {
            let local = adapter.records(scope).await?;
            let ids = local
                .records
                .into_iter()
                .map(|record| record.record_id)
                .chain(local.unreadable);
            held.entry(adapter.kind()).or_default().extend(ids);
        }
        Ok(held)
    }

    // What a move of personal data here takes and what stays on the device (0054, Moving between providers).
    pub(crate) async fn personal_plan(&self) -> Result<MovePlan, SyncError> {
        let categories = self.categories();
        let mut plan = MovePlan {
            records: 0,
            staying_behind: 0,
            secrets_to_seal: 0,
        };
        for adapter in self.adapters.in_scope(ScopeName::Personal) {
            let kind = adapter.kind();
            for record in adapter.records(ScopeName::Personal).await?.records {
                let goes = record.standing == Standing::Syncs && categories.syncs(kind);
                match (goes, kind) {
                    (true, Kind::SecretEnvelope) => plan.secrets_to_seal += 1,
                    (true, _) => plan.records += 1,
                    (false, _) => plan.staying_behind += 1,
                }
            }
        }
        Ok(plan)
    }

    // Every personal row but the key objects': bases, held records, refill copies, waiting values and the batch in
    // flight, so nothing an earlier spell on TablePro Sync agreed stands in for the copy the arrival meets. A first
    // upload refills, in the same commit, each kind that lives in the personal scope alone (0066, Per-kind refills),
    // so the marks outlive a restart and a kind a team scope shares, as the envelopes, takes no refill there.
    async fn let_go_of_personal(
        &self,
        refills: bool,
        from: Option<Provider>,
        fence: &MoveFence<'_>,
    ) -> Result<(), SyncError> {
        let scope = ScopeName::Personal;
        let mut txn = begin(&self.state).await?;
        txn.put(Row::Move(MoveRow {
            from,
            target: Provider::Service,
            phase: MovePhase::Open,
        }))
        .await?;
        if refills {
            for adapter in self.adapters.in_scope(scope) {
                let kind = adapter.kind();
                if kind.is_key() || kind.scopes() != [tablepro_records::Scope::Personal] {
                    continue;
                }
                txn.put(Row::StoresKind(StoresKindRow {
                    store: adapter.store().to_owned(),
                    kind: KindName::of(kind),
                }))
                .await?;
            }
        }
        for table in [
            Table::Bases,
            Table::Held,
            Table::Deferred,
            Table::Approvals,
            Table::Conflicts,
        ] {
            for row in txn.scan(&RowRange::Scope(table, scope)).await? {
                let key = match &row {
                    Row::Base(row) => &row.key,
                    Row::Held(row) => &row.key,
                    Row::Deferred(row) => &row.key,
                    Row::Approval(row) => &row.key,
                    Row::Conflict(row) => &row.key,
                    _ => continue,
                };
                if !key.kind.is_key() {
                    txn.delete(&row.key()).await?;
                }
            }
        }
        txn.delete(&RowKey::Outbox(scope)).await?;
        if let Some(Row::Scope(mut row)) = txn.get(&RowKey::Scope(scope)).await? {
            row.cursor = None;
            row.read_kinds.clear();
            txn.put(Row::Scope(row)).await?;
        }
        let _held = fence.hold().await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    async fn pass_locked(
        &self,
        session: &mut Session,
        why: PassReason,
        arrival: Option<Arc<Arrival>>,
    ) -> Result<PassReport, SyncError> {
        tracing::debug!(?why, "sync pass");
        // A move back to iCloud, open or done, keeps personal data resting here until the person moves it again, and so
        // does a managed policy that forbids it.
        if self.policy_rests() {
            *self.mode.lock().unwrap_or_else(PoisonError::into_inner) = ServiceMode::TeamsOnly;
        }
        if matches!(
            self.move_row().await,
            Ok(Some(MoveRow {
                target: Provider::ICloud,
                ..
            }))
        ) {
            *self.mode.lock().unwrap_or_else(PoisonError::into_inner) = ServiceMode::TeamsOnly;
        }
        self.set_phase(SyncPhase::Syncing);
        self.before_team_pass().await;
        let taken = self.journal.take();
        let named = (why == PassReason::Journal).then(|| taken.clone());
        let journal_only = named.is_some();
        let outcome = self.run(session, named, arrival).await;
        self.after_team_pass(session, &outcome).await;
        if let Ok(keys) = self.keys.key_state().await {
            self.hooks.read_keys(keys);
        }
        if outcome.is_err() {
            self.journal.give_back(taken);
        }
        if let Err(SyncError::Transport(TransportError::DeviceRemoved)) = &outcome {
            crate::api::key_flows::KeyHooks::lock(self.hooks.as_ref(), LockCause::DeviceRemoved);
        }
        self.finish(&outcome, journal_only).await;
        outcome
    }

    async fn run(
        &self,
        session: &mut Session,
        named: Option<JournalIds>,
        arrival: Option<Arc<Arrival>>,
    ) -> Result<PassReport, SyncError> {
        self.check_stop()?;
        self.refill_stale_file(session).await?;
        self.count_recovery_wait().await?;
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
            mode: self.mode(),
            arrival,
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
        ctx.report.reached.clone_from(&names);
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
                ScopeName::Team(_) => !self.team_library_off(),
                ScopeName::Personal => ctx.keyed && !locked,
                ScopeName::History => {
                    ctx.mode == ServiceMode::Personal && ctx.keyed && !locked && info.approved == Some(true)
                }
            })
            .cloned()
            .collect()
    }

    // Each store's identity against what the state saw (0054, Store identity; 0060). A new generation or a lower
    // sequence, or a store the state never saw, as on the first pass or after a stale file, owes each of its kinds a
    // refill in `stores_kinds`, in the commit that moves its row (0066, Per-kind refills). A kind takes it once its
    // category is on, so a pass cut short, or a kind that is off, refills later.
    async fn read_stores(&self, ctx: &mut PassCtx, scopes: &[ScopeInfo]) -> Result<(), SyncError> {
        // The stores the file held rows of as this pass began, before it writes any.
        let known: HashSet<String> = begin(&self.state)
            .await?
            .scan(&RowRange::Table(Table::Stores))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Store(row) => Some(row.store),
                _ => None,
            })
            .collect();
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
                        if stored.is_none() && carried_over(txn.as_mut(), &store, *kind, &known).await? {
                            continue;
                        }
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
                    self.check_stop()?;
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
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        for row in rows {
            txn.put(row).await?;
        }
        self.check_stop()?;
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
                // A scope this mode does not carry the kind in, as the personal scope of a teams-only pass, meets it
                // again when it arrives, so only the scopes that carry it take the refill.
                let scopes: Vec<ScopeName> = seen
                    .scopes
                    .iter()
                    .copied()
                    .filter(|held| ctx.categories_in(*held).syncs(*kind))
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
            self.check_stop()?;
            let mut txn = begin(&self.state).await?;
            for row in txn.scan(&RowRange::Table(Table::Stores)).await? {
                txn.delete(&row.key()).await?;
            }
            txn.delete(&RowKey::Move).await?;
            self.check_stop()?;
            txn.commit().await?;
        }
        session.stale_handled = true;
        Ok(())
    }

    // A journal pass diffs only what it was told of, so the count it saw is not what waits.
    async fn finish(&self, outcome: &Result<PassReport, SyncError>, journal_only: bool) {
        let counts = self.counts().await;
        if let (Ok(report), false) = (outcome, journal_only) {
            self.queued
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone_from(&report.queued_in);
        }
        let queued = self.queued_shown();
        let mut status = self.status_lock();
        status.last_pass_ms = Some(self.clock.now_ms());
        match outcome {
            Ok(report) => {
                // A record the store refused is held, never dropped silently: the pass that held it says so.
                status.problem = (!report.store_refused.is_empty()).then_some(crate::api::error::UNREADABLE);
                if !journal_only {
                    status.queued_changes = queued;
                }
                status.phase = if report.push_wait.is_some() {
                    SyncPhase::NewIdentity
                } else if report.pull_only {
                    SyncPhase::PullOnly
                } else {
                    SyncPhase::Idle
                };
            }
            // A switch to teams-only ended the pass; the next one runs at once.
            Err(SyncError::Cancelled) if self.switching() && !self.stop.is_stopped() => {
                status.phase = SyncPhase::Idle;
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
        let count = |rows: Vec<Row>| {
            rows.iter()
                .filter(|row| match row {
                    Row::Held(row) => self.shows(&row.key),
                    Row::Conflict(row) => self.shows(&row.key),
                    Row::Approval(row) => row.decision == ApprovalDecision::Waiting && self.shows(&row.key),
                    _ => false,
                })
                .count()
        };
        let held = count(txn.scan(&RowRange::Table(Table::Held)).await?);
        let conflicts = count(txn.scan(&RowRange::Table(Table::Conflicts)).await?);
        let approvals = count(txn.scan(&RowRange::Table(Table::Approvals)).await?);
        let counted = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
        Ok((counted(held), counted(conflicts), counted(approvals)))
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

impl Fence for ServiceSync {
    fn check(&self) -> Result<(), SyncError> {
        self.check_stop()
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
        let mut waiting = self.queue().waiting().await?;
        waiting.retain(|approval| self.shows(&approval.key));
        Ok(waiting)
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
        if !self.shows(&key) {
            return Err(SyncError::NotAllowed {
                what: "decide on personal data while TablePro Sync is not the personal provider",
            });
        }
        self.queue().decide(&key, &field, seen, approve).await?;
        drop(session);
        self.refresh_counts().await;
        self.decided(&key);
        Ok(())
    }

    async fn conflicts(&self) -> Result<Vec<TeamConflict>, SyncError> {
        let _session = self.session.lock().await;
        let mut open = self.conflict_table().open().await?;
        open.retain(|conflict| self.shows(&conflict.key));
        Ok(open)
    }

    async fn resolve_conflict(&self, key: RecordKey, seen: [u8; 32], keep: ConflictChoice) -> Result<(), SyncError> {
        let session = self.session.lock().await;
        if !self.shows(&key) {
            return Err(SyncError::NotAllowed {
                what: "decide on personal data while TablePro Sync is not the personal provider",
            });
        }
        let mine = self.team_conflict_side(&key).await?;
        if let (Some(_), ConflictChoice::KeepMine) = (&mine, keep) {
            let _read = self.team_keep_mine().await?;
            let fence = team_library::TeamCommitFence(self);
            Conflicts {
                state: &self.state,
                adapters: self.decided_adapters(),
                fence: &fence,
            }
            .resolve(&key, seen, keep)
            .await?;
        } else {
            self.conflict_table().resolve(&key, seen, keep).await?;
        }
        if let Some(mine) = mine {
            self.team_resolved(&key, keep, mine).await?;
        }
        drop(session);
        self.refresh_counts().await;
        self.decided(&key);
        Ok(())
    }

    async fn load_older_history(&self) -> Result<bool, SyncError> {
        let _session = self.session.lock().await;
        if self.mode() == ServiceMode::TeamsOnly {
            return Ok(false);
        }
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
        held.retain(|record| self.shows(&record.key));
        Ok(held)
    }
}
