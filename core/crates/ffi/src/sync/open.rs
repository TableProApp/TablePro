// Opening sync: the host's services under the engine's traits, then each engine the app's choices let run.

use std::sync::Arc;

use tablepro_records::Kind;
use tablepro_session::runtime::Tasks;
use tablepro_sync::SyncError;
use tablepro_sync::api::{self as sync, StateFiles, TransportError};
use tablepro_sync::cloudkit::LegacyMarks;
use tablepro_sync::engine::SystemClock;
use tablepro_sync::service::ServiceMode;
use tablepro_sync::state::SqliteStateFiles;

use super::cloudkit::{CloudKitBridge, CloudKitTransport};
use super::engines::{Hosts, IcloudEngine, Restart, ServiceEngine, ServiceLink, ServiceSlot, service_link};
use super::events::{Signals, forward};
use super::host::{HostDeviceStore, HostDeviceStoreBridge, HostSettings, HostSettingsBridge};
use super::legacy::{HostLegacyMirror, LegacyMirrorBridge};
use super::service::{SyncConfig, SyncListener, SyncPlatformTag, SyncService};
use super::service_records::categories_arg;
use crate::account::{AccountService, SyncProviderTag};
use crate::core_handle::Core;
use crate::error::CoreError;
use crate::runtime::on_runtime;

// What `SyncService::open` runs over, the host's services already under the engine's traits.
pub(crate) struct OpenParts {
    pub(crate) config: SyncConfig,
    pub(crate) account: Option<Arc<AccountService>>,
    // This Core's state files; None on a Core opened without storage.
    pub(crate) files: Option<Arc<dyn StateFiles>>,
    pub(crate) connections: Option<tablepro_storage::ConnectionStore>,
    pub(crate) cloudkit: Option<Arc<dyn sync::CloudKitTransport>>,
    pub(crate) settings: Option<Arc<dyn sync::HostSettings>>,
    pub(crate) device_store: Option<Arc<dyn sync::HostDeviceStore>>,
    pub(crate) legacy_mirror: Option<Arc<dyn sync::LegacyMirror>>,
    // The sign-in's `/v2/sync` link, or why there is none.
    pub(crate) link: Result<ServiceLink, SyncError>,
    // The sign-in's session as sync opened, read before the link, which a later start must still be.
    pub(crate) session: Option<String>,
    pub(crate) listener: Arc<dyn SyncListener>,
}

#[uniffi::export]
impl Core {
    // The engine keeps its state files in this Core's folders and syncs this Core's stores, so it opens on the Core that
    // holds them. `account` may come from another Core; with none, as for iCloud alone, TablePro Sync is unavailable and
    // iCloud runs (core ADR 0054, Providers). TablePro Sync stays bound to the sign-in the account holds at open, so
    // after a sign-in, a sign-out or a switch the app opens it again. The Apple apps pass their CloudKit transport and device store, and the
    // Mac its legacy mirror while the previous stable runs the Swift engine. Windows passes none: the core reaches
    // Credential Manager itself. Async, since opening a state file reads its anchor from the device store.
    #[expect(
        clippy::too_many_arguments,
        reason = "a UniFFI record cannot carry callback interfaces, so each host service is its own argument"
    )]
    pub async fn open_sync(
        &self,
        config: SyncConfig,
        account: Option<Arc<AccountService>>,
        cloudkit: Option<Arc<dyn CloudKitTransport>>,
        settings: Option<Arc<dyn HostSettings>>,
        device_store: Option<Box<dyn HostDeviceStore>>,
        legacy_mirror: Option<Box<dyn HostLegacyMirror>>,
        listener: Box<dyn SyncListener>,
    ) -> Result<Arc<SyncService>, CoreError> {
        let tasks = self.tasks.clone();
        let kind = match config.platform {
            SyncPlatformTag::Macos => Kind::MacosSettings,
            SyncPlatformTag::Ios => Kind::IosSettings,
            SyncPlatformTag::Linux => Kind::LinuxSettings,
            SyncPlatformTag::Windows => Kind::WindowsSettings,
        };
        let device_store = device_store
            .map(|host| {
                Arc::new(HostDeviceStoreBridge {
                    host: Arc::from(host),
                    tasks: tasks.clone(),
                }) as Arc<dyn sync::HostDeviceStore>
            })
            .or_else(|| own_device_store(&tasks));
        let files = match (&self.paths, &device_store) {
            (Some(paths), Some(store)) => {
                Some(Arc::new(SqliteStateFiles::new(paths, Arc::clone(store))) as Arc<dyn StateFiles>)
            }
            _ => None,
        };
        let mut parts = OpenParts {
            config,
            account,
            files,
            connections: self.store.clone(),
            cloudkit: cloudkit.map(|host| Arc::new(CloudKitBridge(host)) as Arc<dyn sync::CloudKitTransport>),
            settings: settings.map(|host| Arc::new(HostSettingsBridge { host, kind }) as Arc<dyn sync::HostSettings>),
            device_store,
            legacy_mirror: legacy_mirror.map(|host| {
                Arc::new(LegacyMirrorBridge {
                    host: Arc::from(host),
                    tasks: tasks.clone(),
                }) as Arc<dyn sync::LegacyMirror>
            }),
            link: Err(TransportError::SignedOut.into()),
            session: None,
            listener: Arc::from(listener),
        };
        let opener = tasks.clone();
        on_runtime(&opener, async move {
            parts.session = parts.account.as_deref().and_then(Restart::session_of);
            parts.link = service_link(parts.account.as_deref()).await;
            Ok(SyncService::open(tasks, parts).await)
        })
        .await
    }
}

// Windows keeps its device items in Credential Manager; another platform's app passes its own store or has none.
#[cfg(windows)]
fn own_device_store(tasks: &Tasks) -> Option<Arc<dyn sync::HostDeviceStore>> {
    let manager = crate::credential_manager::CredentialManager::new(crate::credential_manager::PREFIX, tasks.clone());
    Some(Arc::new(crate::credential_manager::DeviceItems(Arc::new(manager))))
}

#[cfg(not(windows))]
fn own_device_store(_: &Tasks) -> Option<Arc<dyn sync::HostDeviceStore>> {
    None
}

impl SyncService {
    // On the runtime. An engine that cannot start keeps why, which its calls answer; the others run.
    pub(crate) async fn open(tasks: Tasks, parts: OpenParts) -> Arc<Self> {
        let (cloudkit, files) = (parts.cloudkit.clone(), parts.files.clone());
        let signals = Arc::new(Signals::default());
        let forwarding = forward(Arc::clone(&signals), parts.listener, &tasks);
        let hosts = match (parts.files, parts.device_store) {
            (Some(files), Some(device_store)) => Ok(Hosts {
                files,
                device_store,
                settings: parts.settings,
                events: signals,
            }),
            (None, _) => Err(SyncError::NotAllowed {
                what: "sync on a Core opened without storage",
            }),
            (Some(_), None) => Err(SyncError::NotAllowed {
                what: "sync without a device store",
            }),
        };
        let categories = categories_arg(&parts.config.categories);
        let mirror = parts.legacy_mirror;
        let icloud = match (parts.config.provider, parts.cloudkit, &hosts, &categories) {
            (SyncProviderTag::Icloud, Some(transport), Ok(hosts), Ok(categories)) => Ok(IcloudEngine::start(
                hosts,
                transport,
                categories,
                parts.config.icloud_account.clone(),
                mirror.clone(),
            )),
            (SyncProviderTag::Icloud, None, _, _) => Err(SyncError::NotAllowed {
                what: "sync with iCloud without a CloudKit transport",
            }),
            (SyncProviderTag::Icloud, _, Err(error), _) | (SyncProviderTag::Icloud, _, _, Err(error)) => {
                Err(error.clone())
            }
            (SyncProviderTag::Off | SyncProviderTag::TableproSync, ..) => Err(SyncError::NotAllowed {
                what: "sync with iCloud while it is not the chosen provider",
            }),
        };
        // The previous stable marks every write whatever its provider, so with no iCloud engine to carry the marks
        // they go on their own (0054, Downgrade mirror).
        let legacy_marks = match (&icloud, mirror) {
            (Err(_), Some(mirror)) => Some(Arc::new(LegacyMarks::new(mirror, Arc::new(SystemClock)))),
            _ => None,
        };
        let kept = categories.clone().unwrap_or_default();
        let mode = match parts.config.provider {
            SyncProviderTag::TableproSync => ServiceMode::Personal,
            SyncProviderTag::Icloud | SyncProviderTag::Off => ServiceMode::TeamsOnly,
        };
        let restart = match (&parts.account, &hosts) {
            (Some(account), Ok(hosts)) => Some(Restart {
                hosts: hosts.clone(),
                account: Arc::clone(account),
                mode,
                session: parts.session.clone(),
            }),
            _ => None,
        };
        let first = match (parts.link, &hosts, categories) {
            (Ok(link), Ok(hosts), Ok(categories)) => ServiceEngine::start(hosts, link, categories, mode).await,
            (Err(error), ..) | (_, _, Err(error)) => Err(error),
            (_, Err(error), _) => Err(error.clone()),
        };
        Arc::new(Self {
            tasks,
            account: parts.account,
            config: parts.config,
            icloud,
            service: Arc::new(ServiceSlot::new(first, restart, kept)),
            connections: parts.connections,
            legacy_marks,
            cloudkit,
            files,
            _forward: forwarding,
        })
    }
}
