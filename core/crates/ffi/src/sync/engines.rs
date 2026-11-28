// The engines a `SyncService` runs (core ADR 0054, Providers): iCloud for personal data when the app picked it, and
// TablePro Sync for one sign-in, which carries personal data too when it is the personal provider and the team scopes
// and key objects always, each over this Core's state files, with its own journal, scheduler and stop.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use tablepro_keys::encoding::{AccountId, Origin};
use tablepro_records::Kind;
use tablepro_storage::{ConnectionStore, QueryHistory, SavedQueryDatabase};
use tablepro_sync::SyncError;
use tablepro_sync::adapters::categories::DeviceCategories;
use tablepro_sync::adapters::envelopes::EnvelopeAdapter;
use tablepro_sync::adapters::history::HistoryAdapter;
use tablepro_sync::adapters::library::{self, DriverNames, Provider};
use tablepro_sync::adapters::saved_queries::SavedQueryAdapter;
use tablepro_sync::adapters::settings::{ConnectionStanding, SettingsAdapter};
use tablepro_sync::adapters::store_journal::{Listening, StoreJournal};
use tablepro_sync::adapters::team_library::TeamLibraryAdapter;
use tablepro_sync::api::control::{PassReason, SyncCategories, SyncControl};
use tablepro_sync::api::key_flows::KeyFlows;
use tablepro_sync::api::state::StateIdentity;
use tablepro_sync::api::{
    CloudKitTransport, DeviceRowId, DeviceSecrets, DeviceStoreError, HostDeviceStore, HostSettings, LegacyMirror,
    RecordAdapter, ServiceTransport, StateError, StateFiles, StateStore, TransportError,
};
use tablepro_sync::cloudkit::LegacyMarks;
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{
    Adapters, Backoff, EngineEvents, EngineHooks, Journal, JournalEntry, JournalObserver, Pass, SchedulerHandle,
    StopSignal, SystemClock, Wake, retryable, spawn,
};
use tablepro_sync::http::{Binding, HttpTransport};
use tablepro_sync::keys::{KeyService, KeyServiceParts};
use tablepro_sync::service::{ServiceMode, ServiceParts, ServiceSync};

use super::team_library::TeamLibraryHost;
use crate::account::AccountService;

// What the service engine runs over for one sign-in: who it is, and the `/v2/sync` transport that signs its calls.
#[derive(Clone)]
pub(crate) struct ServiceLink {
    pub(crate) origin: Origin,
    pub(crate) sign_in: String,
    pub(crate) account: AccountId,
    pub(crate) device_row: DeviceRowId,
    pub(crate) transport: Arc<dyn ServiceTransport>,
    // The account's sign-in the transport is bound to, which the account's own calls for the same engine must still be.
    pub(crate) binding: Option<Binding>,
}

impl ServiceLink {
    fn session(&self) -> Option<&str> {
        self.binding.as_ref().and_then(Binding::session_id)
    }
}

// The sign-in the account holds now, which the service engine stays bound to for its life.
pub(crate) async fn service_link(account: Option<&AccountService>) -> Result<ServiceLink, SyncError> {
    let Some(service) = account else {
        return Err(TransportError::SignedOut.into());
    };
    let http = service.account.http_client();
    let transport = HttpTransport::open(Arc::new(service.account.clone()), http).await?;
    let binding = transport.binding().clone();
    Ok(ServiceLink {
        origin: binding.origin.clone(),
        sign_in: binding.sign_in.clone(),
        account: binding.account,
        device_row: binding.device_row.clone(),
        transport: Arc::new(transport),
        binding: Some(binding),
    })
}

// The app's services and this Core's state files, which both engines share.
#[derive(Clone)]
pub(crate) struct Hosts {
    pub(crate) files: Arc<dyn StateFiles>,
    pub(crate) device_store: Arc<dyn HostDeviceStore>,
    pub(crate) settings: Option<Arc<dyn HostSettings>>,
    pub(crate) events: Arc<dyn EngineEvents>,
    // This Core's connection library: connections, groups, tags and profiles, named by `names`.
    pub(crate) library: Option<ConnectionStore>,
    pub(crate) names: DriverNames,
    // This device's id as the host keeps it, which names the SSH routes it publishes.
    pub(crate) publisher: Option<uuid::Uuid>,
    // This Core's query history, and the store of its saved queries, their folders, favourites and table folders.
    pub(crate) history: Option<QueryHistory>,
    pub(crate) saved_queries: Option<SavedQueryDatabase>,
    // Which connections stay on this device. Until it is known, no history syncs and nothing of a connection does
    // (0051, What syncs).
    pub(crate) standing: Option<Arc<dyn ConnectionStanding>>,
    // What the stores' writes tell each engine that syncs them.
    pub(crate) store_journal: Arc<StoreJournal>,
    // Team Library's store and sign-in, which only the service engine syncs.
    pub(crate) team_library: Option<TeamLibraryHost>,
    // The device's secrets, which go up sealed into envelopes on TablePro Sync only; iCloud carries them in iCloud
    // Keychain (0054, Providers).
    pub(crate) secrets: Option<Arc<dyn DeviceSecrets>>,
}

impl Hosts {
    // The adapters over this Core's stores and the app's settings.
    fn adapters(&self, provider: Provider) -> Vec<Arc<dyn RecordAdapter>> {
        let mut adapters: Vec<Arc<dyn RecordAdapter>> = self
            .settings
            .iter()
            .map(|host| {
                Arc::new(SettingsAdapter::new(Arc::clone(host), self.standing.clone())) as Arc<dyn RecordAdapter>
            })
            .collect();
        // The table folders and favourites the saved queries' store holds come with the library, which says which of
        // their connections sync.
        if let Some(store) = &self.library {
            adapters.extend(library::adapters(
                store,
                self.saved_queries.as_ref(),
                self.names,
                provider,
                self.publisher,
            ));
        }
        if let Some(saved) = &self.saved_queries {
            adapters.extend(SavedQueryAdapter::all(saved, self.standing.clone()));
        }
        if let (Some(history), Some(standing)) = (&self.history, &self.standing) {
            adapters.push(Arc::new(HistoryAdapter::new(history.clone(), Arc::clone(standing))));
        }
        adapters
    }

    // The personal envelopes over the device's secrets, sealed and opened by this sign-in's keys and compared with the
    // copies its state file agreed on.
    fn envelopes(&self, keys: &Arc<KeyService>, state: &Arc<dyn StateStore>) -> Option<Arc<dyn RecordAdapter>> {
        let (store, secrets) = (self.library.as_ref()?, self.secrets.as_ref()?);
        Some(Arc::new(EnvelopeAdapter::new(
            store,
            self.names,
            self.publisher,
            Arc::clone(secrets),
            Arc::clone(keys) as Arc<dyn KeyFlows>,
            Arc::clone(state),
        )))
    }

    // The stores' writes tell `listener` until the handle drops with what holds it.
    pub(crate) fn listen(&self, listener: Arc<dyn JournalObserver>) -> Option<Listening> {
        (self.library.is_some()
            || self.history.is_some()
            || self.saved_queries.is_some()
            || self.team_library.is_some())
        .then(|| self.store_journal.listen(listener))
    }
}

// The kinds whose category is on, as the iCloud engine takes them.
pub(crate) fn icloud_categories(categories: &SyncCategories) -> Categories {
    let device = DeviceCategories::from(categories);
    Categories::new(Kind::ALL.into_iter().filter(|kind| device.syncs(*kind)))
}

pub(crate) struct IcloudEngine {
    pub(crate) sync: Arc<CloudKitSync>,
    pub(crate) journal: Journal,
    stop: StopSignal,
    _scheduler: SchedulerHandle,
    _stores: Option<Listening>,
}

impl IcloudEngine {
    // Called on the runtime, which the scheduler's task needs.
    pub(crate) fn start(
        hosts: &Hosts,
        transport: Arc<dyn CloudKitTransport>,
        categories: &SyncCategories,
        last_account: Option<String>,
        legacy_mirror: Option<Arc<dyn LegacyMirror>>,
    ) -> Self {
        let wake = Wake::new();
        let journal = Journal::new(wake.clone());
        let stop = StopSignal::new();
        let sync = CloudKitSync::new(CloudKitParts {
            transport,
            files: Arc::clone(&hosts.files),
            adapters: hosts.adapters(Provider::ICloud),
            categories: icloud_categories(categories),
            clock: Arc::new(SystemClock),
            stop: stop.clone(),
            journal: journal.clone(),
            events: Some(Arc::clone(&hosts.events)),
            last_account,
        });
        // While the previous stable still runs the Swift engine, the Mac writes what that build reads (0054,
        // Downgrade mirror).
        let sync = Arc::new(match legacy_mirror {
            Some(mirror) => sync.with_legacy_mirror(mirror),
            None => sync,
        });
        let scheduler = spawn(
            Arc::clone(&sync) as Arc<dyn Pass>,
            wake,
            stop.clone(),
            Backoff::STANDARD,
        );
        let stores = hosts.listen(Arc::new(journal.clone()));
        Self {
            sync,
            journal,
            stop,
            _scheduler: scheduler,
            _stores: stores,
        }
    }
}

impl IcloudEngine {
    // The person turned sync off: no pass runs until the app opens sync again.
    pub(crate) fn stop(&self) {
        self.stop.stop();
    }
}

impl Drop for IcloudEngine {
    // The pass in flight drops its CloudKit call, which cancels the Swift task.
    fn drop(&mut self) {
        self.stop.stop();
    }
}

pub(crate) struct ServiceEngine {
    pub(crate) sync: Arc<ServiceSync>,
    pub(crate) keys: Arc<KeyService>,
    pub(crate) journal: Journal,
    pub(crate) binding: Option<Binding>,
    stop: StopSignal,
    _scheduler: SchedulerHandle,
    _stores: Option<Listening>,
}

// The state file a sign-in names, as text the app keeps between launches (`SyncConfig::service_account`).
pub(crate) fn identity_text(identity: &StateIdentity) -> Option<String> {
    let StateIdentity::Service {
        origin,
        sign_in,
        account,
        device_row,
    } = identity
    else {
        return None;
    };
    serde_json::to_string(&[
        origin.as_str(),
        sign_in.as_str(),
        account.to_wire().as_str(),
        device_row.0.as_str(),
    ])
    .ok()
}

// Text the app kept that names no sign-in reads as no previous one.
pub(crate) fn identity_of(text: &str) -> Option<StateIdentity> {
    let [origin, sign_in, account, device_row]: [String; 4] = serde_json::from_str(text).ok()?;
    Some(StateIdentity::Service {
        origin: Origin::parse(&origin).ok()?,
        sign_in,
        account: AccountId::from_wire(&account).ok()?,
        device_row: DeviceRowId(device_row),
    })
}

// Another account, or the same account on another server; a new sign-in of the same account is not one.
fn another_sign_in(previous: &StateIdentity, origin: &Origin, account: AccountId) -> bool {
    match previous {
        StateIdentity::Service {
            origin: last_origin,
            account: last_account,
            ..
        } => last_origin != origin || *last_account != account,
        StateIdentity::ICloud { .. } => false,
    }
}

impl ServiceEngine {
    // Called on the runtime: it opens the sign-in's state file, and the scheduler's task needs the runtime. A sign-in
    // to another account or server than `last` named counts what that file held unsent, for the Move my data or Start
    // empty prompt, and lets the file go, as iCloud does with the last account's file (0054, Another account or
    // server).
    pub(crate) async fn start(
        hosts: &Hosts,
        link: ServiceLink,
        categories: SyncCategories,
        mode: ServiceMode,
        last: Option<StateIdentity>,
    ) -> Result<Self, SyncError> {
        let binding = link.binding;
        let identity = StateIdentity::Service {
            origin: link.origin.clone(),
            sign_in: link.sign_in,
            account: link.account,
            device_row: link.device_row.clone(),
        };
        let state = hosts.files.open(identity).await?;
        let previous = last.filter(|previous| another_sign_in(previous, &link.origin, link.account));
        let follows = match &previous {
            Some(previous) => {
                let old = hosts.files.open(previous.clone()).await?;
                let adapters = Adapters::new(hosts.adapters(Provider::TableproSync));
                let unsent = tablepro_sync::service::unsent_changes(&old, &adapters).await?;
                drop(old);
                Some(unsent)
            }
            None => None,
        };
        let wake = Wake::new();
        let journal = Journal::new(wake.clone());
        let stop = StopSignal::new();
        let hooks = Arc::new(EngineHooks::new(wake.clone(), Some(Arc::clone(&hosts.events))));
        let team_library = hosts
            .team_library
            .as_ref()
            .map(|host| host.store(&link.origin, link.account, &hosts.store_journal));
        let origin = link.origin.clone();
        let keys = Arc::new(KeyService::new(KeyServiceParts {
            origin: link.origin,
            account: link.account,
            device_row: link.device_row,
            state: Arc::clone(&state),
            device_store: Arc::clone(&hosts.device_store),
            transport: Arc::clone(&link.transport),
            hooks: Arc::clone(&hooks) as _,
            clock: Arc::new(tablepro_sync::keys::SystemClock),
        }));
        let mut adapters = hosts.adapters(Provider::TableproSync);
        adapters.extend(hosts.envelopes(&keys, &state));
        adapters.extend(team_library.iter().flat_map(TeamLibraryAdapter::all));
        let sync = Arc::new(ServiceSync::new(ServiceParts {
            transport: link.transport,
            state,
            adapters: Adapters::new(adapters),
            keys: Arc::clone(&keys) as Arc<dyn KeyFlows>,
            hooks,
            clock: Arc::new(SystemClock),
            stop: stop.clone(),
            journal: journal.clone(),
            events: Some(Arc::clone(&hosts.events)),
            categories,
            mode,
            follows,
        }));
        if let (Some(host), Some(store)) = (&hosts.team_library, team_library) {
            let session = binding
                .as_ref()
                .and_then(|binding| binding.session_id().map(str::to_owned));
            host.attach(&sync, store, session, origin).await;
        }
        // The wait comes from the sign-in the app kept, outside the file, on every open until the person chooses, so a
        // file put back from a backup cannot lose it. The last file stays until then, for the count.
        if previous.is_some() {
            sync.hold_for_account_choice().await?;
        }
        sync.read_counts().await;
        let scheduler = spawn(
            Arc::clone(&sync) as Arc<dyn Pass>,
            wake,
            stop.clone(),
            Backoff::STANDARD,
        );
        let stores = hosts.listen(Arc::new(journal.clone()));
        // Nothing else asks for a pass while sync is off or right after a sign-in, and until one reads the scopes the
        // key state stays unknown (E2E F8).
        journal.pass_soon(PassReason::Launch);
        Ok(Self {
            sync,
            keys,
            journal,
            binding,
            stop,
            _scheduler: scheduler,
            _stores: stores,
        })
    }
}

impl ServiceEngine {
    // The values no longer allow the server it is bound to: no pass runs and none in flight commits more (0055).
    pub(crate) fn stop(&self) {
        self.stop.stop();
    }
}

impl Drop for ServiceEngine {
    // A task that still holds the key flows keeps no recovery key a sheet left behind.
    fn drop(&mut self) {
        self.stop.stop();
        self.keys.drafts().clear();
    }
}

// What a later start of the service engine needs, for a first start that failed for a reason that passes.
pub(crate) struct Restart {
    pub(crate) hosts: Hosts,
    pub(crate) account: Arc<AccountService>,
    pub(crate) mode: ServiceMode,
    // The sign-in the account held when sync opened, which a later start must still be: another one opens sync again.
    pub(crate) session: Option<String>,
    // The sign-in whose state file this device used last (`SyncConfig::service_account`).
    pub(crate) last: Option<StateIdentity>,
}

impl Restart {
    // The account's sign-in at this moment, by its session id, which no file keeps and each sign-in renews.
    pub(crate) fn session_of(account: &AccountService) -> Option<String> {
        match &*account.account.status().borrow() {
            tablepro_account::AccountStatus::SignedIn(signed_in) => signed_in.session_id.clone(),
            tablepro_account::AccountStatus::SignedOut | tablepro_account::AccountStatus::Offline(_) => None,
        }
    }
}

// The open's own start, kept while the state file it names is still held by the service the app is closing, as when
// the app opens TablePro Sync's service before the one it replaces is gone (E2E F7).
#[derive(Clone)]
pub(crate) struct WaitingStart {
    pub(crate) hosts: Hosts,
    pub(crate) link: ServiceLink,
    pub(crate) mode: ServiceMode,
    pub(crate) last: Option<StateIdentity>,
}

// How often a start waiting for the state file looks again, and how long a call waits for it before it answers
// `sync.state.busy`. A closing service lets go once its calls in flight end.
pub(crate) const FILE_POLL: Duration = Duration::from_millis(100);
const FILE_WAIT_TRIES: u32 = 50;
const FILE_POLL_MAX: Duration = Duration::from_secs(5);

// The TablePro Sync engine, or why it is not running. A start that failed for a reason that passes, as the network or
// a locked device store, is tried again by the next call that needs the engine, for the same sign-in only; any other
// failure holds until the app opens sync again. A start that found the state file busy goes on by itself once the file
// is free.
pub(crate) struct ServiceSlot {
    held: Mutex<Result<Arc<ServiceEngine>, SyncError>>,
    starting: tokio::sync::Mutex<()>,
    restart: Option<Restart>,
    waiting: Mutex<Option<WaitingStart>>,
    // What the person set while no engine ran, which the next start takes.
    categories: Mutex<SyncCategories>,
    history_window: Mutex<Option<u32>>,
    // The values no longer allow personal data on TablePro Sync: a later start runs teams-only (0055).
    personal_forbidden: std::sync::atomic::AtomicBool,
    // And no move on a later engine brings it back while they say so.
    policy_forbids: std::sync::atomic::AtomicBool,
}

// An anchor the device store could not settle, as while it is locked, is no pass's to retry (0066) but a start's.
fn passes(error: &SyncError) -> bool {
    retryable(error)
        || matches!(
            error,
            SyncError::DeviceStore(DeviceStoreError::Locked) | SyncError::State(StateError::AnchorUnsettled)
        )
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn busy<T>(result: &Result<T, SyncError>) -> bool {
    matches!(result, Err(SyncError::State(StateError::Busy)))
}

impl ServiceSlot {
    pub(crate) fn new(
        first: Result<ServiceEngine, SyncError>,
        restart: Option<Restart>,
        waiting: Option<WaitingStart>,
        categories: SyncCategories,
    ) -> Self {
        let waiting = waiting.filter(|_| busy(&first));
        Self {
            held: Mutex::new(first.map(Arc::new)),
            starting: tokio::sync::Mutex::new(()),
            restart,
            waiting: Mutex::new(waiting),
            categories: Mutex::new(categories),
            history_window: Mutex::new(None),
            personal_forbidden: std::sync::atomic::AtomicBool::new(false),
            policy_forbids: std::sync::atomic::AtomicBool::new(false),
        }
    }

    pub(crate) fn forbid_by_policy(&self) {
        self.policy_forbids.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub(crate) fn forbid_personal(&self) {
        self.personal_forbidden.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    // The engine as it stands, with no start: for the calls that answer at once.
    pub(crate) fn now(&self) -> Result<Arc<ServiceEngine>, SyncError> {
        lock(&self.held).clone()
    }

    pub(crate) fn waits_for_file(&self) -> bool {
        lock(&self.waiting).is_some()
    }

    // On the runtime: a start that failed for a reason that passes is tried again first.
    pub(crate) async fn engine(&self) -> Result<Arc<ServiceEngine>, SyncError> {
        let failed = match self.now() {
            Ok(engine) => return Ok(engine),
            Err(error) => error,
        };
        if self.waits_for_file() {
            return self.wait_for_file().await;
        }
        let Some(restart) = self.restart.as_ref().filter(|_| passes(&failed)) else {
            return Err(failed);
        };
        let _starting = self.starting.lock().await;
        if let Ok(engine) = self.now() {
            return Ok(engine);
        }
        let categories = lock(&self.categories).clone();
        let started = match service_link(Some(&restart.account)).await {
            Ok(link) if restart.session.is_some() && link.session() == restart.session.as_deref() => {
                ServiceEngine::start(
                    &restart.hosts,
                    link,
                    categories,
                    self.mode(restart.mode),
                    restart.last.clone(),
                )
                .await
            }
            Ok(_) => Err(TransportError::SignedOut.into()),
            Err(error) => Err(error),
        };
        self.adopt(started)
    }

    // A call waits a moment for the closing service to let go of the file.
    async fn wait_for_file(&self) -> Result<Arc<ServiceEngine>, SyncError> {
        let mut started = self.start_waiting().await;
        for _ in 1..FILE_WAIT_TRIES {
            if !busy(&started) {
                break;
            }
            tokio::time::sleep(FILE_POLL).await;
            started = self.start_waiting().await;
        }
        started
    }

    // The open's start once more, under the sign-in it opened with; a sign-in changed since gets none.
    async fn start_waiting(&self) -> Result<Arc<ServiceEngine>, SyncError> {
        let _starting = self.starting.lock().await;
        if let Ok(engine) = self.now() {
            return Ok(engine);
        }
        let Some(waiting) = lock(&self.waiting).clone() else {
            return self.now();
        };
        let signed_in_since = self
            .restart
            .as_ref()
            .is_some_and(|restart| Restart::session_of(&restart.account) != restart.session);
        let started = if signed_in_since {
            Err(TransportError::SignedOut.into())
        } else {
            let categories = lock(&self.categories).clone();
            ServiceEngine::start(
                &waiting.hosts,
                waiting.link,
                categories,
                self.mode(waiting.mode),
                waiting.last,
            )
            .await
        };
        if !busy(&started) {
            *lock(&self.waiting) = None;
        }
        self.adopt(started)
    }

    // With no call to wait on it, the engine starts once the file is free, and the app hears the new status.
    pub(crate) async fn start_when_free(slot: Weak<Self>) {
        let mut wait = FILE_POLL;
        loop {
            tokio::time::sleep(wait).await;
            let Some(slot) = slot.upgrade() else { return };
            let Some(events) = lock(&slot.waiting)
                .as_ref()
                .map(|waiting| Arc::clone(&waiting.hosts.events))
            else {
                return;
            };
            if busy(&slot.start_waiting().await) {
                wait = (wait * 2).min(FILE_POLL_MAX);
                continue;
            }
            events.status_changed();
            return;
        }
    }

    fn mode(&self, opened: ServiceMode) -> ServiceMode {
        if self.personal_forbidden.load(std::sync::atomic::Ordering::SeqCst) {
            ServiceMode::TeamsOnly
        } else {
            opened
        }
    }

    fn adopt(&self, started: Result<ServiceEngine, SyncError>) -> Result<Arc<ServiceEngine>, SyncError> {
        let started = started.map(Arc::new);
        if let Ok(engine) = &started {
            engine.sync.set_history_window(*lock(&self.history_window));
            if self.policy_forbids.load(std::sync::atomic::Ordering::SeqCst) {
                engine.sync.forbid_personal();
            }
        }
        *lock(&self.held) = started.clone();
        started
    }

    // Waits for a start in flight, which takes them before its engine runs, so no change is lost to one.
    pub(crate) async fn set_categories(&self, categories: SyncCategories) -> Result<(), SyncError> {
        let _starting = self.starting.lock().await;
        *lock(&self.categories) = categories.clone();
        match self.now() {
            Ok(engine) => engine.sync.set_categories(categories).await,
            Err(_) => Ok(()),
        }
    }

    pub(crate) fn set_history_window(&self, entries: Option<u32>) {
        *lock(&self.history_window) = entries;
        if let Ok(engine) = self.now() {
            engine.sync.set_history_window(entries);
        }
    }
}

// A store the app keeps wrote, after the write landed (core ADR 0060). Each engine's diff decides what goes up.
// The downgrade mirror's marks, when no iCloud engine carries them, take the same signal.
pub(crate) fn journal(
    journals: &[&Journal],
    marks: Option<&LegacyMarks>,
    kind: Kind,
    written: Vec<String>,
    deleted: Vec<String>,
) {
    let entry = JournalEntry { kind, written, deleted };
    for journal in journals {
        journal.changed(std::slice::from_ref(&entry));
    }
    if let Some(marks) = marks {
        marks.changed(std::slice::from_ref(&entry));
    }
}

#[cfg(test)]
#[path = "engines_tests.rs"]
mod tests;
