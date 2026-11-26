// The engines a `SyncService` runs (core ADR 0054, Providers): iCloud for personal data when the app picked it, and
// TablePro Sync for one sign-in, each over this Core's state files, with its own journal, scheduler and stop.

use std::sync::Arc;

use tablepro_keys::encoding::{AccountId, Origin};
use tablepro_records::Kind;
use tablepro_storage::QueryHistory;
use tablepro_sync::SyncError;
use tablepro_sync::adapters::categories::DeviceCategories;
use tablepro_sync::adapters::history::HistoryAdapter;
use tablepro_sync::adapters::saved_queries::SavedQueryAdapter;
use tablepro_sync::adapters::settings::{ConnectionStanding, SettingsAdapter};
use tablepro_sync::adapters::store_journal::StoreJournal;
use tablepro_sync::api::control::SyncCategories;
use tablepro_sync::api::key_flows::KeyFlows;
use tablepro_sync::api::state::StateIdentity;
use tablepro_sync::api::{
    CloudKitTransport, DeviceRowId, HostDeviceStore, HostSettings, RecordAdapter, ServiceTransport, StateFiles,
};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{
    Adapters, Backoff, EngineEvents, EngineHooks, Journal, JournalEntry, Pass, SchedulerHandle, StopSignal,
    SystemClock, Wake, spawn,
};
use tablepro_sync::keys::{KeyService, KeyServiceParts};
use tablepro_sync::service::{ServiceParts, ServiceSync};

// What the service engine runs over for one sign-in: who it is, and the `/v2/sync` transport that signs its calls.
pub(crate) struct ServiceLink {
    pub(crate) origin: Origin,
    pub(crate) sign_in: String,
    pub(crate) account: AccountId,
    pub(crate) device_row: DeviceRowId,
    pub(crate) transport: Arc<dyn ServiceTransport>,
}

// The app's services and this Core's state files, which both engines share.
pub(crate) struct Hosts {
    pub(crate) files: Arc<dyn StateFiles>,
    pub(crate) device_store: Arc<dyn HostDeviceStore>,
    pub(crate) settings: Option<Arc<dyn HostSettings>>,
    pub(crate) events: Arc<dyn EngineEvents>,
    // This Core's history database: its saved queries, their folders and the query history.
    pub(crate) history: Option<QueryHistory>,
    // Which connections stay on this device. Until it is known, no history syncs (0051, What syncs).
    pub(crate) standing: Option<Arc<dyn ConnectionStanding>>,
    // What the history database's writes tell each engine that syncs it.
    pub(crate) store_journal: Arc<StoreJournal>,
}

impl Hosts {
    // The adapters over this Core's stores and the app's settings; the stores' writes now also tell `journal`.
    fn adapters(&self, journal: &Journal) -> Vec<Arc<dyn RecordAdapter>> {
        let mut adapters: Vec<Arc<dyn RecordAdapter>> = self
            .settings
            .iter()
            .map(|host| Arc::new(SettingsAdapter::new(Arc::clone(host), None)) as Arc<dyn RecordAdapter>)
            .collect();
        if let Some(history) = &self.history {
            self.store_journal.add(journal.clone());
            adapters.extend(SavedQueryAdapter::all(history));
            if let Some(standing) = &self.standing {
                adapters.push(Arc::new(HistoryAdapter::new(history.clone(), Arc::clone(standing))));
            }
        }
        adapters
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
}

impl IcloudEngine {
    // Called on the runtime, which the scheduler's task needs.
    pub(crate) fn start(
        hosts: &Hosts,
        transport: Arc<dyn CloudKitTransport>,
        categories: &SyncCategories,
        last_account: Option<String>,
    ) -> Self {
        let wake = Wake::new();
        let journal = Journal::new(wake.clone());
        let stop = StopSignal::new();
        let sync = Arc::new(CloudKitSync::new(CloudKitParts {
            transport,
            files: Arc::clone(&hosts.files),
            adapters: hosts.adapters(&journal),
            categories: icloud_categories(categories),
            clock: Arc::new(SystemClock),
            stop: stop.clone(),
            journal: journal.clone(),
            events: Some(Arc::clone(&hosts.events)),
            last_account,
        }));
        let scheduler = spawn(
            Arc::clone(&sync) as Arc<dyn Pass>,
            wake,
            stop.clone(),
            Backoff::STANDARD,
        );
        Self {
            sync,
            journal,
            stop,
            _scheduler: scheduler,
        }
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
    stop: StopSignal,
    _scheduler: SchedulerHandle,
}

impl ServiceEngine {
    // Called on the runtime: it opens the sign-in's state file, and the scheduler's task needs the runtime.
    pub(crate) async fn start(hosts: &Hosts, link: ServiceLink, categories: SyncCategories) -> Result<Self, SyncError> {
        let identity = StateIdentity::Service {
            origin: link.origin.clone(),
            sign_in: link.sign_in,
            account: link.account,
            device_row: link.device_row.clone(),
        };
        let state = hosts.files.open(identity).await?;
        let wake = Wake::new();
        let journal = Journal::new(wake.clone());
        let stop = StopSignal::new();
        let hooks = Arc::new(EngineHooks::new(wake.clone(), Some(Arc::clone(&hosts.events))));
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
        let sync = Arc::new(ServiceSync::new(ServiceParts {
            transport: link.transport,
            state,
            adapters: Adapters::new(hosts.adapters(&journal)),
            keys: Arc::clone(&keys) as Arc<dyn KeyFlows>,
            hooks,
            clock: Arc::new(SystemClock),
            stop: stop.clone(),
            journal: journal.clone(),
            events: Some(Arc::clone(&hosts.events)),
            categories,
        }));
        let scheduler = spawn(
            Arc::clone(&sync) as Arc<dyn Pass>,
            wake,
            stop.clone(),
            Backoff::STANDARD,
        );
        Ok(Self {
            sync,
            keys,
            journal,
            stop,
            _scheduler: scheduler,
        })
    }
}

impl Drop for ServiceEngine {
    fn drop(&mut self) {
        self.stop.stop();
    }
}

// A store the app keeps wrote, after the write landed (core ADR 0060). Each engine's diff decides what goes up.
pub(crate) fn journal(journals: &[&Journal], kind: Kind, written: Vec<String>, deleted: Vec<String>) {
    let entry = JournalEntry { kind, written, deleted };
    for journal in journals {
        journal.changed(std::slice::from_ref(&entry));
    }
}

#[cfg(test)]
#[path = "engines_tests.rs"]
mod tests;
