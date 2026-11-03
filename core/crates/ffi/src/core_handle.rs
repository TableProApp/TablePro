use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::future::BoxFuture;
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{CredentialInteraction, SecretItems, SecretKind, SecretVault};
use tablepro_core::{
    ConnectEnvironment, Credentials, DatabaseDriver, DriverError, DriverRegistry, FileEndpoint, LivenessPolicy,
    SafeModeLevel, SshFailure, TransportError, WorkspaceSettings,
};
use tablepro_driver_host::{DriverStore, PlatformTrust, Signer, Trust};
use tablepro_session::connect::{SshTunnel, SshTunnels};
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectError, ConnectRequest, ConnectServices, ConnectionMetadata, Connector, CredentialSource, DefaultDeadlines,
    DriverConnector, NoStoredCredentials, RefreshedRequest, RequestTarget, Session, SessionDeps, resolve_saved,
};
use tablepro_ssh::{SshAuth, SshConfig};
use tablepro_storage::{ConnectionStore, CredentialDemand, KeyringCredentials, SavedConnection, StoragePaths};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::cancel_token::{CancelToken, token};
use crate::driver_plugins::DriverPlugins;
use crate::drivers::{self, DriverInfo};
use crate::error::CoreError;
use crate::host::{HostConfig, HostSecretStore, HostSecrets};
use crate::library::{ConnectionLibrary, ConnectionRecord, ConnectionSecrets, apply, blank, parse_id};
use crate::runtime::{self, on_runtime};
use crate::session::DatabaseSession;

/// The library's root: the linked engines, the runtime and what the app
/// passed in. An app makes one and keeps it.
#[derive(uniffi::Object)]
pub struct Core {
    registry: Arc<DriverRegistry>,
    connector: Arc<DriverConnector>,
    deadlines: Arc<DefaultDeadlines>,
    vault: Arc<dyn SecretVault>,
    items: Arc<dyn SecretItems>,
    store: Option<ConnectionStore>,
    plugins: Option<Arc<DriverStore>>,
    tasks: Tasks,
}

/// A database file to open.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileOpenRequest {
    /// An absolute path.
    pub path: String,
    /// The engine to open it with. `None` lets the file's first bytes
    /// decide, then its name.
    pub driver_id: Option<String>,
    pub read_only: bool,
    /// Make a new database at `path`, which must not exist yet.
    pub create: bool,
}

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(config: HostConfig, secrets: Box<dyn HostSecrets>) -> Result<Arc<Self>, CoreError> {
        let tasks = runtime::tasks()?;
        let host = Arc::new(HostSecretStore::new(secrets, tasks.clone()));
        Ok(Self::build(config, host.clone(), host, tasks))
    }

    // Secrets go to the platform's own store: Credential Manager on Windows.
    #[uniffi::constructor]
    pub fn with_system_secrets(config: HostConfig) -> Result<Arc<Self>, CoreError> {
        let tasks = runtime::tasks()?;
        let (vault, items) = system_secrets(&tasks)?;
        Ok(Self::build(config, vault, items, tasks))
    }

    /// Every engine linked in, by name.
    pub fn drivers(&self) -> Vec<DriverInfo> {
        let mut drivers: Vec<DriverInfo> = self
            .registry
            .iter()
            .map(|driver| DriverInfo::of(driver.as_ref()))
            .collect();
        drivers.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        drivers
    }

    /// The drivers the user installed, in the storage folder's `drivers`.
    pub fn driver_plugins(&self) -> Result<Arc<DriverPlugins>, CoreError> {
        let store = self.plugins.clone().ok_or_else(no_storage)?;
        Ok(Arc::new(DriverPlugins::new(store, self.tasks.clone())))
    }

    pub fn library(&self) -> Result<Arc<ConnectionLibrary>, CoreError> {
        let store = self.store.clone().ok_or_else(no_storage)?;
        Ok(Arc::new(ConnectionLibrary::new(
            store,
            self.vault.clone(),
            self.tasks.clone(),
        )))
    }

    pub async fn open_file(
        &self,
        request: FileOpenRequest,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<DatabaseSession>, CoreError> {
        let registry = self.registry.clone();
        let connector = self.connector.clone();
        let deadlines = self.deadlines.clone();
        let tasks = self.tasks.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let path = PathBuf::from(&request.path);
            let endpoint = match request.create {
                true => FileEndpoint::create_new(path.clone()),
                false => FileEndpoint::open_existing(path.clone()),
            }
            .map_err(DriverError::from)?;
            let driver = match request.driver_id {
                Some(id) => registry.get(&id).ok_or(ConnectError::UnknownDriver(id))?,
                None => file_engine(&registry, &tasks, path.clone()).await?,
            };
            let mut connect = ConnectRequest {
                metadata: ConnectionMetadata {
                    id: Uuid::new_v4(),
                    name: file_name(&path),
                    driver_id: driver.id().to_owned(),
                },
                driver,
                target: RequestTarget::File(endpoint),
                workspace_settings: WorkspaceSettings::workspace(false),
                safe_mode: SafeModeLevel::default(),
            };
            if request.read_only {
                connect.open_read_only();
            }
            let pending = connector
                .establish(connect, CredentialInteraction::Unattended, cancel)
                .await?;
            let session = Session::start(
                pending,
                SessionDeps {
                    connector,
                    credentials: Arc::new(NoStoredCredentials),
                    deadlines,
                    tasks: tasks.clone(),
                    prompter: None,
                },
            );
            Ok(Arc::new(DatabaseSession::new(session, tasks)))
        })
        .await
    }

    // Secrets typed now come first; Credential Manager supplies the rest.
    pub async fn connect_saved(
        &self,
        id: String,
        secrets: ConnectionSecrets,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<DatabaseSession>, CoreError> {
        let id = parse_id(&id)?;
        let store = self.store.clone().ok_or_else(no_storage)?;
        let registry = self.registry.clone();
        let connector = self.connector.clone();
        let deadlines = self.deadlines.clone();
        let vault = self.vault.clone();
        let tasks = self.tasks.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let reader = store.clone();
            let saved = tasks
                .spawn_blocking_task(move || reader.list_blocking())
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??
                .connections
                .iter()
                .find(|saved| saved.id == id)
                .cloned()
                .ok_or_else(|| CoreError::failed("storage.connection_not_found", format!("no connection {id}")))?;
            let credentials = Arc::new(Prefilled::new(&saved, vault, &secrets));
            let refreshed = resolve_saved(
                &saved,
                &registry,
                credentials.as_ref(),
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await?;
            let pending = connector
                .establish(refreshed.request, CredentialInteraction::Unattended, cancel.clone())
                .await?;
            if cancel.is_cancelled() {
                let report = pending.discard().await;
                tracing::debug!(
                    ?report,
                    "closed a connection that arrived after its connect was cancelled"
                );
                return Err(CoreError::Cancelled);
            }
            let session = Session::start(
                pending,
                SessionDeps {
                    connector,
                    credentials,
                    deadlines,
                    tasks: tasks.clone(),
                    prompter: None,
                },
            );
            let stamped = tasks
                .spawn_blocking_task(move || store.touch_last_opened_blocking(id))
                .await;
            if let Ok(Err(error)) = stamped {
                tracing::warn!(%error, "could not record when the connection was opened");
            }
            Ok(Arc::new(DatabaseSession::new(session, tasks)))
        })
        .await
    }

    pub async fn test_connection(
        &self,
        record: ConnectionRecord,
        secrets: ConnectionSecrets,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<(), CoreError> {
        let id = match record.id.trim() {
            "" => Uuid::new_v4(),
            id => parse_id(id)?,
        };
        let mut saved = blank(id);
        let name = record.name.trim().to_owned();
        apply(&record, name, None, &mut saved);
        let registry = self.registry.clone();
        let connector = self.connector.clone();
        let vault = self.vault.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let credentials = Prefilled::new(&saved, vault, &secrets);
            let refreshed = resolve_saved(
                &saved,
                &registry,
                &credentials,
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await?;
            let pending = connector
                .establish(refreshed.request, CredentialInteraction::Unattended, cancel)
                .await?;
            let report = pending.discard().await;
            tracing::debug!(?report, "closed the test connection");
            Ok(())
        })
        .await
    }
}

impl Core {
    fn build(config: HostConfig, vault: Arc<dyn SecretVault>, items: Arc<dyn SecretItems>, tasks: Tasks) -> Arc<Self> {
        let liveness = LivenessPolicy::DESKTOP;
        let deadlines = Arc::new(DefaultDeadlines::new(liveness));
        let services = ConnectServices {
            environment: ConnectEnvironment::new(config.client_version),
            ssh: Arc::new(NoSshTransport),
            liveness,
        };
        let storage_dir = config.storage_dir.filter(|dir| !dir.trim().is_empty());
        let store = storage_dir
            .as_ref()
            .map(|dir| ConnectionStore::new(&storage_paths(Path::new(dir))));
        let signers = config
            .driver_signers
            .into_iter()
            .map(|signer| Signer {
                subject: signer.subject,
                issuer_sha256: signer.issuer_sha256,
            })
            .collect();
        // HostConfig makes the host responsible for trusting these publishers and their native code.
        let trust: Arc<dyn Trust> = Arc::new(unsafe { PlatformTrust::new(signers) });
        let plugins = storage_dir.map(|dir| Arc::new(DriverStore::new(Path::new(&dir).join("drivers"), trust)));
        Arc::new(Self {
            registry: Arc::new(drivers::registry()),
            connector: Arc::new(DriverConnector::new(services, deadlines.clone())),
            deadlines,
            vault,
            items,
            store,
            plugins,
            tasks,
        })
    }

    pub fn secret_vault(&self) -> Arc<dyn SecretVault> {
        self.vault.clone()
    }

    pub fn secret_items(&self) -> Arc<dyn SecretItems> {
        self.items.clone()
    }
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("drivers", &self.registry.len())
            .finish_non_exhaustive()
    }
}

// One folder holds every kind of file, as a packaged app's LocalState does.
fn storage_paths(root: &Path) -> StoragePaths {
    StoragePaths {
        config: root.to_path_buf(),
        state: root.join("state"),
        data: root.join("data"),
        cache: root.join("cache"),
        runtime: root.join("runtime"),
    }
}

fn no_storage() -> CoreError {
    CoreError::failed("ffi.no_storage", "the core was started without a storage folder")
}

type SystemSecrets = (Arc<dyn SecretVault>, Arc<dyn SecretItems>);

#[cfg(windows)]
fn system_secrets(tasks: &Tasks) -> Result<SystemSecrets, CoreError> {
    let manager = Arc::new(crate::credential_manager::CredentialManager::new(
        "TablePro",
        tasks.clone(),
    ));
    Ok((manager.clone(), manager))
}

#[cfg(not(windows))]
fn system_secrets(_tasks: &Tasks) -> Result<SystemSecrets, CoreError> {
    Err(CoreError::failed(
        "ffi.no_system_secret_store",
        "this platform's secret store is not built into the core",
    ))
}

// Secrets the form or a prompt holds go into the request first; the rest come from the vault.
struct Prefilled {
    typed: Vec<(SecretKind, SecretString)>,
    keyring: KeyringCredentials,
}

impl Prefilled {
    fn new(saved: &SavedConnection, vault: Arc<dyn SecretVault>, secrets: &ConnectionSecrets) -> Self {
        let typed = secrets.typed();
        let kinds: Vec<SecretKind> = typed.iter().map(|(kind, _)| *kind).collect();
        Self {
            typed,
            keyring: KeyringCredentials::for_saved(vault, saved).keeping_session_secrets(&kinds),
        }
    }
}

impl CredentialSource for Prefilled {
    fn refresh(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
        let mut request = request;
        fill(&mut request, &self.typed);
        let typed: Vec<SecretKind> = self.typed.iter().map(|(kind, _)| *kind).collect();
        // A typed secret may be empty, for a server that takes none, which the keyring would read as missing.
        if needed(&request).iter().all(|kind| typed.contains(kind)) {
            return Box::pin(async move { Ok(RefreshedRequest::unchanged(request)) });
        }
        self.keyring.refresh(request, interaction, demand)
    }

    fn remember(
        &self,
        saves: Vec<tablepro_core::credentials::SecretSave>,
    ) -> BoxFuture<'static, Vec<(SecretKind, tablepro_core::credentials::SecretError)>> {
        self.keyring.remember(saves)
    }
}

fn fill(request: &mut ConnectRequest, typed: &[(SecretKind, SecretString)]) {
    let RequestTarget::Network { credentials, ssh, .. } = &mut request.target else {
        return;
    };
    for (kind, secret) in typed {
        let secret = SecretString::from(secret.expose_secret().to_owned());
        match (kind, &mut *credentials, ssh.as_mut().map(|ssh| &mut ssh.auth)) {
            (SecretKind::DatabasePassword, Credentials::Password { password, .. }, _) => *password = secret,
            (SecretKind::SshPassword, _, Some(SshAuth::Password { password })) => *password = secret,
            (SecretKind::SshPassphrase, _, Some(SshAuth::PrivateKey { passphrase, .. })) => {
                *passphrase = Some(secret);
            }
            _ => {}
        }
    }
}

fn needed(request: &ConnectRequest) -> Vec<SecretKind> {
    let RequestTarget::Network { credentials, ssh, .. } = &request.target else {
        return Vec::new();
    };
    let mut kinds = Vec::new();
    if matches!(credentials, Credentials::Password { .. }) {
        kinds.push(SecretKind::DatabasePassword);
    }
    match ssh.as_ref().map(|ssh| &ssh.auth) {
        Some(SshAuth::Password { .. }) => kinds.push(SecretKind::SshPassword),
        Some(SshAuth::PrivateKey { .. }) => kinds.push(SecretKind::SshPassphrase),
        _ => {}
    }
    kinds
}

// A missing file is no error here: it fails only once it is opened.
async fn file_engine(
    registry: &DriverRegistry,
    tasks: &Tasks,
    path: PathBuf,
) -> Result<Arc<dyn DatabaseDriver>, CoreError> {
    let length = registry.file_header_len();
    let read_path = path.clone();
    let header = tasks
        .spawn_blocking_task(move || read_header(&read_path, length))
        .await
        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        .map_err(|kind| file_error(&path, kind))?;
    registry
        .file_driver_for(&header, &path)
        .ok_or_else(|| CoreError::failed("ffi.no_file_engine", format!("no engine opens {}", path.display())))
}

fn read_header(path: &Path, length: usize) -> Result<Vec<u8>, std::io::ErrorKind> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.kind()),
    };
    let mut header = Vec::with_capacity(length);
    file.take(u64::try_from(length).unwrap_or(u64::MAX))
        .read_to_end(&mut header)
        .map_err(|error| error.kind())?;
    Ok(header)
}

fn file_error(path: &Path, kind: std::io::ErrorKind) -> CoreError {
    let path = path.to_path_buf();
    CoreError::from(match kind {
        std::io::ErrorKind::PermissionDenied => DriverError::FileAccessDenied { path },
        kind => DriverError::FileIo { path, kind },
    })
}

fn file_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

// No SSH transport is wired in yet, so SSH fails as it would with no client installed.
#[derive(Debug)]
struct NoSshTransport;

impl SshTunnels for NoSshTransport {
    fn open(
        &self,
        _config: &SshConfig,
        _liveness: LivenessPolicy,
        _interaction: CredentialInteraction,
        _cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<Arc<dyn SshTunnel>, TransportError>> {
        Box::pin(async {
            Err(TransportError::Ssh(SshFailure::OpenSshClientMissing {
                program: PathBuf::from("ssh"),
            }))
        })
    }
}
