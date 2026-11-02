use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialInteraction, SecretItems, SecretVault};
use tablepro_core::{
    ConnectEnvironment, DatabaseDriver, DriverError, DriverRegistry, FileEndpoint, LivenessPolicy, SafeModeLevel,
    SshFailure, TransportError, WorkspaceSettings,
};
use tablepro_session::connect::{SshTunnel, SshTunnels};
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectError, ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, RequestTarget, Session, SessionDeps,
};
use tablepro_ssh::SshConfig;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::cancel_token::{CancelToken, token};
use crate::drivers::{self, DriverInfo};
use crate::error::CoreError;
use crate::host::{HostConfig, HostSecretStore, HostSecrets};
use crate::runtime::{self, on_runtime};
use crate::session::DatabaseSession;

/// The library's root: the linked engines, the runtime and what the app
/// passed in. An app makes one and keeps it.
#[derive(uniffi::Object)]
pub struct Core {
    registry: Arc<DriverRegistry>,
    connector: Arc<DriverConnector>,
    deadlines: Arc<DefaultDeadlines>,
    secrets: Arc<HostSecretStore>,
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
        let liveness = LivenessPolicy::DESKTOP;
        let deadlines = Arc::new(DefaultDeadlines::new(liveness));
        let services = ConnectServices {
            environment: ConnectEnvironment::new(config.client_version),
            ssh: Arc::new(NoSshTransport),
            liveness,
        };
        Ok(Arc::new(Self {
            registry: Arc::new(drivers::registry()),
            connector: Arc::new(DriverConnector::new(services, deadlines.clone())),
            deadlines,
            secrets: Arc::new(HostSecretStore::new(secrets, tasks.clone())),
            tasks,
        }))
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
}

impl Core {
    /// The app's secret store, for a connection's keyring credentials.
    pub fn secret_vault(&self) -> Arc<dyn SecretVault> {
        self.secrets.clone()
    }

    /// The app's secret store, for the secrets no connection owns.
    pub fn secret_items(&self) -> Arc<dyn SecretItems> {
        self.secrets.clone()
    }
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("drivers", &self.registry.len())
            .finish_non_exhaustive()
    }
}

/// The engine whose signature the file's first bytes carry, read on a
/// blocking thread. A missing file is only a problem when it is opened.
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

/// No SSH transport is wired into the library yet, so a connection
/// through SSH fails as one would with no client installed.
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
