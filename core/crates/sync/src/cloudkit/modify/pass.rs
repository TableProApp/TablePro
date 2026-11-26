// The iCloud pass (0054, The CloudKit transport; Scheduling): the account signed in now, its state file, the zone, the
// fetch and then the push. Another iCloud account deletes the last account's state file and starts its own from a full
// fetch. A call that finds the account changed ends the pass with nothing of its results kept and drops the state
// file, so the next pass reads the account again. A removed zone clears the state and nothing goes up until the person
// asks to upload again. On the Mac, the Swift engine's metadata is imported at the first pass over a state file and
// written back after every pass while the previous stable runs that engine (0054, Downgrade mirror).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;

use super::{PushReport, Pusher, Waits, zone};
use crate::adapters::approval::Queue;
use crate::api::adapter::RecordAdapter;
use crate::api::cloudkit::{CloudKitFailure, CloudKitTransport};
use crate::api::control::{
    HeldRecord, HeldRecordReason, PassReason, PendingApproval, SyncControl, SyncPhase, SyncStatus,
};
use crate::api::error::SyncError;
use crate::api::ids::RecordKey;
use crate::api::legacy::LegacyMirror;
use crate::api::state::{Provider, Row, RowRange, StateFiles, StateIdentity, StateStore, SyncTrust, Table};
use crate::cloudkit::fetch::{Categories, FetchReport, Fetcher, SCOPE, read_everything_again};
use crate::cloudkit::legacy::{Context, LegacyLink};
use crate::engine::{Adapters, Clock, EngineEvents, Journal, JournalIds, Pass, StopSignal};

// The Swift engine's fallback timer, for changes no CloudKit push announced.
const FALLBACK: Duration = Duration::from_secs(15 * 60);

pub struct CloudKitParts {
    pub transport: Arc<dyn CloudKitTransport>,
    pub files: Arc<dyn StateFiles>,
    pub adapters: Vec<Arc<dyn RecordAdapter>>,
    pub categories: Categories,
    pub clock: Arc<dyn Clock>,
    pub stop: StopSignal,
    pub journal: Journal,
    pub events: Option<Arc<dyn EngineEvents>>,
    // The iCloud account whose state file this device used last, which the host keeps as the Swift engine kept its
    // account; None on first use. `CloudKitSync::account` says what to keep. The state files cannot be listed, so this
    // is how a switch made while the app was closed deletes the old account's file.
    pub last_account: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudKitReport {
    pub account: String,
    // The account this device synced with before, whose state file the pass deleted.
    pub switched_from: Option<String>,
    // This device made the zone: it had never seen it, or the person asked to upload again.
    pub zone_made: bool,
    pub fetch: FetchReport,
    pub push: PushReport,
    // How long until the first record CloudKit asked to wait may go again, while one waits.
    pub waiting_ms: Option<u64>,
}

impl CloudKitReport {
    // CloudKit asked a record to wait, or to be tried again later: the scheduler waits it out as a throttle, so the
    // pass after it sends what waited (0054, Scheduling).
    pub fn throttle(&self) -> Option<CloudKitFailure> {
        let retry_after_ms = self
            .fetch
            .retry_after_ms
            .max(self.push.retry_after_ms)
            .or(self.waiting_ms);
        (retry_after_ms.is_some() || self.push.throttled || self.fetch.throttled)
            .then_some(CloudKitFailure::Throttled { retry_after_ms })
    }
}

#[derive(Default)]
struct Session {
    // The account whose state file this device uses; it outlives a dropped file.
    account: Option<String>,
    state: Option<Arc<dyn StateStore>>,
    // The last pass found the zone removed.
    zone_removed: bool,
    waits: Waits,
    // What the open found of the state file's sync tables was acted on, once per open, as the service's pass does.
    stale_handled: bool,
    // The Swift engine's metadata was read for this state file.
    legacy_checked: bool,
}

pub struct CloudKitSync {
    transport: Arc<dyn CloudKitTransport>,
    files: Arc<dyn StateFiles>,
    adapters: Vec<Arc<dyn RecordAdapter>>,
    // Set by the person at any time, outside the pass, which reads them before each modify call.
    categories: Mutex<Categories>,
    // A category turned on: the next pass reads the zone whole.
    read_again: AtomicBool,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
    journal: Journal,
    events: Option<Arc<dyn EngineEvents>>,
    // One pass at a time per state file (0054, Scheduling).
    session: tokio::sync::Mutex<Session>,
    // The session's account, readable while a pass runs.
    account: Mutex<Option<String>>,
    status: Mutex<SyncStatus>,
    legacy: Option<LegacyLink>,
}

fn identity(account: &str) -> StateIdentity {
    StateIdentity::ICloud {
        user_record_name: account.to_owned(),
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl CloudKitSync {
    pub fn new(parts: CloudKitParts) -> Self {
        Self {
            transport: parts.transport,
            files: parts.files,
            adapters: parts.adapters,
            categories: Mutex::new(parts.categories),
            read_again: AtomicBool::new(false),
            clock: parts.clock,
            stop: parts.stop,
            journal: parts.journal,
            events: parts.events,
            account: Mutex::new(parts.last_account.clone()),
            session: tokio::sync::Mutex::new(Session {
                account: parts.last_account,
                ..Session::default()
            }),
            status: Mutex::new(SyncStatus {
                provider: Some(Provider::ICloud),
                phase: SyncPhase::Idle,
                last_pass_ms: None,
                problem: None,
                waiting_approvals: 0,
                conflicts: 0,
                held: 0,
                queued_changes: 0,
            }),
            legacy: None,
        }
    }

    // The Mac's Swift sync metadata, while the previous stable runs the Swift engine. Called on the runtime: the
    // journal's marks reach the host from a task of their own.
    #[must_use]
    pub fn with_legacy_mirror(mut self, mirror: Arc<dyn LegacyMirror>) -> Self {
        let (link, marks) = LegacyLink::new(mirror, Arc::clone(&self.clock));
        self.journal.observe(marks);
        self.legacy = Some(link);
        self
    }

    // Returns once the journal signals so far have marked the Swift metadata, for the app to await as it quits; fails
    // while the host refuses a mark.
    pub async fn flush_legacy_marks(&self) -> Result<(), SyncError> {
        match &self.legacy {
            Some(legacy) => legacy.flush().await,
            None => Ok(()),
        }
    }

    pub const fn journal(&self) -> &Journal {
        &self.journal
    }

    pub const fn stop_signal(&self) -> &StopSignal {
        &self.stop
    }

    // The account whose state file the device uses now, for the host to keep and hand back at the next launch.
    pub fn account(&self) -> Option<String> {
        lock(&self.account).clone()
    }

    // A category turned off sends nothing from the running pass's next call on. One turned on is read whole on the next
    // fetch: a delta never sends again what earlier fetches passed over, and the deletions that waited for it apply
    // once a full fetch read it.
    pub fn set_categories(&self, categories: Categories) {
        let mut held = lock(&self.categories);
        let turned_on = self
            .adapters
            .iter()
            .any(|adapter| categories.syncs(adapter.kind()) && !held.syncs(adapter.kind()));
        *held = categories;
        if turned_on {
            self.read_again.store(true, Ordering::SeqCst);
        }
    }

    fn set_phase(&self, phase: SyncPhase) {
        lock(&self.status).phase = phase;
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }

    pub async fn run_pass(&self, why: PassReason) -> Result<CloudKitReport, SyncError> {
        let mut session = self.session.lock().await;
        self.run_locked(&mut session, why).await
    }

    // After a removed zone, the person's answer: the zone is made again and everything this device holds goes up.
    // Refused unless a pass found the zone removed.
    pub async fn run_upload_again(&self) -> Result<CloudKitReport, SyncError> {
        let mut session = self.session.lock().await;
        let state = match (&session.state, session.zone_removed) {
            (Some(state), true) => Arc::clone(state),
            _ => return Err(SyncError::NotAllowed { what: "upload again" }),
        };
        self.stop.check()?;
        zone::upload_again(state.as_ref()).await?;
        session.zone_removed = false;
        self.run_locked(&mut session, PassReason::Person).await
    }

    async fn run_locked(&self, session: &mut Session, why: PassReason) -> Result<CloudKitReport, SyncError> {
        tracing::debug!(?why, "icloud pass");
        self.set_phase(SyncPhase::Syncing);
        let taken = self.journal.take();
        let named = (why == PassReason::Journal).then(|| taken.clone());
        // A pass that stops drops the call in flight, which cancels the Swift task and its CloudKit operation.
        let outcome = tokio::select! {
            outcome = self.run(session, named.as_ref()) => outcome,
            () = self.stop.stopped() => Err(SyncError::Cancelled),
        };
        // What a pass left for later is named again, so the journal pass that follows a wait sends it.
        let left = match &outcome {
            Ok(report) => !report.push.failed.is_empty() || report.throttle().is_some(),
            Err(_) => true,
        };
        if left {
            self.journal.give_back(taken);
        }
        self.finish(session, &outcome, named.is_some()).await;
        outcome
    }

    async fn run(&self, session: &mut Session, named: Option<&JournalIds>) -> Result<CloudKitReport, SyncError> {
        self.stop.check()?;
        let account = match self.transport.account_status().await {
            Ok(status) => status.user_record_name,
            Err(failure) => return Err(self.ended(session, failure)),
        };
        let (state, switched_from) = self.open(session, &account).await?;
        self.check_legacy(session, state.as_ref(), &account).await?;
        // A record new to the device that the person approved whole, which a crash kept out of its store, goes in first.
        self.stop.check()?;
        let adapters = Adapters::new(self.adapters.clone());
        self.queue(&state, &adapters).finish_decided().await?;
        let mut report = CloudKitReport {
            account: account.clone(),
            switched_from,
            ..CloudKitReport::default()
        };
        let synced = self.sync(session, state.as_ref(), named, &mut report).await;
        let outcome = self.settle(session, state.as_ref(), synced, report).await;
        self.mirror(session, state.as_ref(), &account, named, &outcome).await;
        outcome
    }

    async fn settle(
        &self,
        session: &mut Session,
        state: &dyn StateStore,
        synced: Result<(), SyncError>,
        report: CloudKitReport,
    ) -> Result<CloudKitReport, SyncError> {
        match synced {
            Ok(()) => {
                session.zone_removed = false;
                Ok(report)
            }
            Err(SyncError::CloudKit(failure)) => {
                let gone = matches!(
                    failure,
                    CloudKitFailure::ZoneNotFound | CloudKitFailure::ZoneDeletedByUser
                );
                if gone && zone::seen(state).await? {
                    self.stop.check()?;
                    zone::removed(state).await?;
                    session.zone_removed = true;
                    session.waits = Waits::default();
                    return Err(failure.into());
                }
                Err(self.ended(session, failure))
            }
            Err(error) => Err(error),
        }
    }

    // Once per state file, before anything is fetched.
    async fn check_legacy(
        &self,
        session: &mut Session,
        state: &dyn StateStore,
        account: &str,
    ) -> Result<(), SyncError> {
        let Some(legacy) = &self.legacy else {
            return Ok(());
        };
        if session.legacy_checked {
            return Ok(());
        }
        self.stop.check()?;
        let categories = lock(&self.categories).clone();
        legacy
            .check(state, self.transport.as_ref(), account, &self.adapters, &categories)
            .await?;
        session.legacy_checked = true;
        Ok(())
    }

    // After a pass that kept its state file, whatever the pass committed. A mirror that fails leaves the pass's own
    // outcome as it was: the next pass writes again.
    async fn mirror(
        &self,
        session: &Session,
        state: &dyn StateStore,
        account: &str,
        named: Option<&JournalIds>,
        outcome: &Result<CloudKitReport, SyncError>,
    ) {
        let Some(legacy) = &self.legacy else {
            return;
        };
        let cancelled = matches!(outcome, Err(SyncError::Cancelled)) || self.stop.is_stopped();
        if !session.legacy_checked || session.state.is_none() || cancelled {
            return;
        }
        let categories = lock(&self.categories).clone();
        let written = legacy
            .write(Context {
                state,
                adapters: &self.adapters,
                categories: &categories,
                account,
                zone_removed: session.zone_removed,
                named,
                now_ms: self.clock.now_ms(),
            })
            .await;
        if let Err(error) = written {
            tracing::warn!(code = error.code(), "the downgrade mirror was not written");
        }
    }

    // A call that found another account keeps nothing of its results, and the state file goes with the pass.
    fn ended(&self, session: &mut Session, failure: CloudKitFailure) -> SyncError {
        if failure == CloudKitFailure::AccountChanged {
            session.state = None;
        }
        failure.into()
    }

    // The state file of the account signed in now (0054, Every call is bound to one account). Another account than the
    // one this device synced with deletes that account's file, and any file this account kept from an earlier session,
    // so it starts from a full fetch with nothing an earlier session knew.
    async fn open(
        &self,
        session: &mut Session,
        account: &str,
    ) -> Result<(Arc<dyn StateStore>, Option<String>), SyncError> {
        let switched_from = session.account.clone().filter(|last| last != account);
        if switched_from.is_none()
            && let Some(state) = &session.state
        {
            return Ok((Arc::clone(state), None));
        }
        session.state = None;
        if let Some(last) = &switched_from {
            self.stop.check()?;
            self.files.delete(identity(last)).await?;
            self.files.delete(identity(account)).await?;
            session.zone_removed = false;
            session.waits = Waits::default();
        }
        let state = self.files.open(identity(account)).await?;
        session.stale_handled = false;
        session.legacy_checked = false;
        if let Some(legacy) = &self.legacy {
            legacy.forget();
        }
        session.account = Some(account.to_owned());
        *lock(&self.account) = Some(account.to_owned());
        session.state = Some(Arc::clone(&state));
        Ok((state, switched_from))
    }

    async fn sync(
        &self,
        session: &mut Session,
        state: &dyn StateStore,
        named: Option<&JournalIds>,
        report: &mut CloudKitReport,
    ) -> Result<(), SyncError> {
        if !zone::seen(state).await? {
            self.stop.check()?;
            self.transport.ensure_zone(report.account.clone()).await?;
            zone::saw(state).await?;
            report.zone_made = true;
        }
        // After the zone's row exists, so a file that lost it to the restore refills too.
        if !session.stale_handled {
            if state.opened().sync_tables == SyncTrust::Refill {
                self.stop.check()?;
                zone::refill(state).await?;
            }
            session.stale_handled = true;
        }
        // Taken together under the lock `set_categories` holds as it sets the flag, so a kind turned on is read whole by
        // the pass that has it on.
        let (categories, read_again) = {
            let held = lock(&self.categories);
            (held.clone(), self.read_again.swap(false, Ordering::SeqCst))
        };
        if read_again && let Err(error) = read_everything_again(state).await {
            self.read_again.store(true, Ordering::SeqCst);
            return Err(error);
        }
        let now_ms = self.clock.now_ms();
        let fetcher = Fetcher::new(self.transport.as_ref(), state, &self.adapters, categories)?
            .stopped_by(self.stop.clone())
            .waiting(session.waits.keys(now_ms));
        report.fetch = fetcher.fetch().await?;
        for (key, wait) in &report.fetch.waits {
            session.waits.hold(key.clone(), now_ms, *wait);
        }
        self.stop.check()?;
        let pusher = Pusher::new(&fetcher, &self.stop, self.clock.now_ms()).following(&self.categories);
        report.push = pusher.push(&mut session.waits, named).await?;
        report.waiting_ms = session.waits.next_in(self.clock.now_ms());
        Ok(())
    }

    // The approval queue over this session's state file and the stores (0054, Rules for both providers).
    fn queue<'q>(&'q self, state: &'q Arc<dyn StateStore>, adapters: &'q Adapters) -> Queue<'q> {
        Queue {
            state,
            adapters,
            fence: &self.stop,
        }
    }

    // The records held by id and the values waiting for the person.
    async fn counts(&self, session: &Session) -> Option<(u32, u32)> {
        let state = session.state.as_ref()?;
        let mut txn = state.begin().await.ok()?;
        let held = txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await.ok()?;
        drop(txn);
        let adapters = Adapters::new(self.adapters.clone());
        let waiting = self.queue(state, &adapters).count().await.ok()?;
        Some((u32::try_from(held.len()).unwrap_or(u32::MAX), waiting))
    }

    // A journal pass diffs only what it was told of, so the count it saw is not what waits.
    async fn finish(&self, session: &Session, outcome: &Result<CloudKitReport, SyncError>, journal_only: bool) {
        let held = self.counts(session).await;
        let mut status = lock(&self.status);
        status.last_pass_ms = Some(self.clock.now_ms());
        match outcome {
            Ok(report) => {
                status.problem = None;
                if !journal_only {
                    status.queued_changes = u32::try_from(report.push.queued).unwrap_or(u32::MAX);
                }
                status.phase = SyncPhase::Idle;
            }
            Err(error) => {
                status.problem = Some(error.code());
                status.phase = if self.stop.is_stopped() {
                    SyncPhase::Off
                } else if session.zone_removed {
                    SyncPhase::ZoneRemoved
                } else {
                    SyncPhase::Idle
                };
            }
        }
        if let Some((held, waiting)) = held {
            status.held = held;
            status.waiting_approvals = waiting;
        }
        drop(status);
        if let Some(events) = &self.events {
            events.status_changed();
        }
    }
}

#[async_trait]
impl Pass for CloudKitSync {
    async fn pass(&self, why: PassReason) -> Result<(), SyncError> {
        let report = self.run_pass(why).await?;
        report.throttle().map_or(Ok(()), |throttle| Err(throttle.into()))
    }

    fn poll_interval(&self) -> Duration {
        FALLBACK
    }

    fn waiting(&self, retry_in_ms: Option<u64>) {
        let phase = lock(&self.status).phase;
        match retry_in_ms {
            Some(retry_in_ms) => self.set_phase(SyncPhase::Waiting { retry_in_ms }),
            None if matches!(phase, SyncPhase::Waiting { .. }) => self.set_phase(SyncPhase::Idle),
            None => {}
        }
    }
}

#[async_trait]
impl SyncControl for CloudKitSync {
    fn status(&self) -> SyncStatus {
        lock(&self.status).clone()
    }

    async fn sync_now(&self, why: PassReason) -> Result<(), SyncError> {
        self.run_pass(why).await.map(|_| ())
    }

    async fn upload_again(&self) -> Result<(), SyncError> {
        self.run_upload_again().await.map(|_| ())
    }

    async fn approvals(&self) -> Result<Vec<PendingApproval>, SyncError> {
        let session = self.session.lock().await;
        let Some(state) = &session.state else {
            return Ok(Vec::new());
        };
        let adapters = Adapters::new(self.adapters.clone());
        self.queue(state, &adapters).waiting().await
    }

    // The records held by id in this account's zone, as the service lists its own (0054, Rules for both providers).
    async fn held_records(&self) -> Result<Vec<HeldRecord>, SyncError> {
        let session = self.session.lock().await;
        let Some(state) = &session.state else {
            return Ok(Vec::new());
        };
        let mut txn = state.begin().await?;
        let rows = txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Held(row) => Some(HeldRecord {
                    key: row.key,
                    reason: HeldRecordReason::Held(row.reason),
                }),
                _ => None,
            })
            .collect())
    }

    async fn decide_approval(
        &self,
        key: RecordKey,
        field: String,
        seen: [u8; 32],
        approve: bool,
    ) -> Result<(), SyncError> {
        let session = self.session.lock().await;
        let state = session.state.as_ref().ok_or(SyncError::Unknown { what: "approval" })?;
        let adapters = Adapters::new(self.adapters.clone());
        self.queue(state, &adapters).decide(&key, &field, seen, approve).await?;
        if let Some((_, waiting)) = self.counts(&session).await {
            lock(&self.status).waiting_approvals = waiting;
        }
        drop(session);
        if let Some(events) = &self.events {
            events.status_changed();
        }
        Ok(())
    }
}
