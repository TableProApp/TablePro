// The iCloud pass (0054, The CloudKit transport; Scheduling): the account signed in now, its state file, the zone, the
// fetch and then the push. Another iCloud account deletes the last account's state file and starts its own from a full
// fetch. A call that finds the account changed ends the pass with nothing of its results kept and drops the state
// file, so the next pass reads the account again. A removed zone clears the state and nothing goes up until the person
// asks to upload again.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;

use super::{PushReport, Pusher, Waits, zone};
use crate::api::adapter::RecordAdapter;
use crate::api::cloudkit::{CloudKitFailure, CloudKitTransport};
use crate::api::control::{PassReason, SyncControl, SyncPhase, SyncStatus};
use crate::api::error::SyncError;
use crate::api::state::{Provider, RowRange, StateFiles, StateIdentity, StateStore, Table};
use crate::cloudkit::fetch::{Categories, FetchReport, Fetcher, SCOPE, read_everything_again};
use crate::engine::{Clock, EngineEvents, Journal, JournalIds, Pass, StopSignal};

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
}

impl CloudKitReport {
    // CloudKit asked a record to wait: the scheduler waits it out as a throttle (0054, Scheduling).
    pub fn throttle(&self) -> Option<CloudKitFailure> {
        let retry_after_ms = self.fetch.retry_after_ms.max(self.push.retry_after_ms);
        (retry_after_ms.is_some() || self.push.throttled).then_some(CloudKitFailure::Throttled { retry_after_ms })
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
}

pub struct CloudKitSync {
    transport: Arc<dyn CloudKitTransport>,
    files: Arc<dyn StateFiles>,
    adapters: Vec<Arc<dyn RecordAdapter>>,
    categories: Mutex<Categories>,
    clock: Arc<dyn Clock>,
    stop: StopSignal,
    journal: Journal,
    events: Option<Arc<dyn EngineEvents>>,
    // One pass at a time per state file (0054, Scheduling).
    session: tokio::sync::Mutex<Session>,
    status: Mutex<SyncStatus>,
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
            clock: parts.clock,
            stop: parts.stop,
            journal: parts.journal,
            events: parts.events,
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
        }
    }

    pub const fn journal(&self) -> &Journal {
        &self.journal
    }

    pub const fn stop_signal(&self) -> &StopSignal {
        &self.stop
    }

    // The account whose state file the device uses now, for the host to keep and hand back at the next launch.
    pub async fn account(&self) -> Option<String> {
        self.session.lock().await.account.clone()
    }

    // A category turned on is read whole on the next fetch: a delta never sends again what earlier fetches passed over,
    // and the deletions that waited for it apply once a full fetch read it.
    pub async fn set_categories(&self, categories: Categories) -> Result<(), SyncError> {
        let session = self.session.lock().await;
        let turned_on = {
            let mut held = lock(&self.categories);
            let on = self
                .adapters
                .iter()
                .any(|adapter| categories.syncs(adapter.kind()) && !held.syncs(adapter.kind()));
            *held = categories;
            on
        };
        if let (true, Some(state)) = (turned_on, &session.state) {
            read_everything_again(state.as_ref()).await?;
        }
        Ok(())
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
        let outcome = self.run(session, named.as_ref()).await;
        if outcome.is_err() {
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
        let mut report = CloudKitReport {
            account,
            switched_from,
            ..CloudKitReport::default()
        };
        match self.sync(session, state.as_ref(), named, &mut report).await {
            Ok(()) => {
                session.zone_removed = false;
                Ok(report)
            }
            Err(SyncError::CloudKit(failure)) => {
                let gone = matches!(
                    failure,
                    CloudKitFailure::ZoneNotFound | CloudKitFailure::ZoneDeletedByUser
                );
                if gone && zone::seen(state.as_ref()).await? {
                    self.stop.check()?;
                    zone::removed(state.as_ref()).await?;
                    session.zone_removed = true;
                    session.waits = Waits::default();
                    return Err(failure.into());
                }
                Err(self.ended(session, failure))
            }
            Err(error) => Err(error),
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
        session.account = Some(account.to_owned());
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
        let categories = lock(&self.categories).clone();
        let fetcher = Fetcher::new(self.transport.as_ref(), state, &self.adapters, categories)?;
        report.fetch = fetcher.fetch().await?;
        self.stop.check()?;
        let pusher = Pusher::new(&fetcher, &self.stop, self.clock.now_ms());
        report.push = pusher.push(&mut session.waits, named).await?;
        Ok(())
    }

    async fn held(&self, session: &Session) -> Option<u32> {
        let state = session.state.as_ref()?;
        let mut txn = state.begin().await.ok()?;
        let held = txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await.ok()?;
        Some(u32::try_from(held.len()).unwrap_or(u32::MAX))
    }

    // A journal pass diffs only what it was told of, so the count it saw is not what waits.
    async fn finish(&self, session: &Session, outcome: &Result<CloudKitReport, SyncError>, journal_only: bool) {
        let held = self.held(session).await;
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
        if let Some(held) = held {
            status.held = held;
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
}
