use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use futures::future::BoxFuture;
use secrecy::SecretString;
use tablepro_account::{AccountSettings, RefreshTokenVault};
use tablepro_core::credentials::{CredentialInteraction, CredentialPrompter, SecretItems, SecretKind, SecretVault};
use tablepro_core::{
    ConnectEnvironment, Credentials, DatabaseDriver, DriverError, DriverRegistry, FileEndpoint, LivenessPolicy,
    SafeModeLevel, WorkspaceSettings,
};
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectError, ConnectRequest, ConnectServices, ConnectionMetadata, Connector, CredentialSource, DefaultDeadlines,
    DriverConnector, NoStoredCredentials, RefreshedRequest, RequestTarget, Session, SessionDeps, resolve_saved,
};
use tablepro_ssh::{InProcessSsh, SshAuth};
use tablepro_storage::{ConnectionStore, CredentialDemand, KeyringCredentials, SavedConnection, StoragePaths};
use tokio::sync::OnceCell;
use uuid::Uuid;

use crate::cancel_token::{CancelToken, token};
use crate::drivers::{self, DriverInfo};
use crate::error::CoreError;
use crate::history::QueryHistoryStore;
use crate::host::{HostConfig, HostSecretStore, HostSecrets};
use crate::library::{
    ConnectionLibrary, ConnectionRecord, ConnectionSecrets, LibraryWrites, apply, blank, keep_proved_secrets, parse_id,
    tls_config,
};
use crate::prompter::{HostPrompter, HostPrompterBridge};
use crate::runtime::{self, on_runtime};
use crate::session::DatabaseSession;

// An app makes one and keeps it.
#[derive(uniffi::Object)]
pub struct Core {
    registry: Arc<DriverRegistry>,
    connector: Arc<DriverConnector>,
    deadlines: Arc<DefaultDeadlines>,
    vault: Arc<dyn SecretVault>,
    items: Arc<dyn SecretItems>,
    // The TablePro account's, in the same store as every other secret.
    refresh_tokens: RefreshTokens,
    paths: Option<StoragePaths>,
    store: Option<ConnectionStore>,
    writes: LibraryWrites,
    // Opened on first use, so a core that never shows history never migrates or prunes it.
    history: Arc<OnceCell<Arc<QueryHistoryStore>>>,
    pub(crate) tasks: Tasks,
    pub(crate) ssh: Arc<InProcessSsh>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileOpenRequest {
    // Absolute.
    pub path: String,
    // None lets the file's first bytes decide the engine, then its name.
    pub driver_id: Option<String>,
    pub read_only: bool,
    // `path` must not exist yet.
    pub create: bool,
}

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(config: HostConfig, secrets: Box<dyn HostSecrets>) -> Result<Arc<Self>, CoreError> {
        let tasks = runtime::tasks()?;
        let host = Arc::new(HostSecretStore::new(secrets, tasks.clone()));
        Ok(Self::build(
            config,
            SystemSecrets {
                vault: host.clone(),
                items: host.clone(),
                // A host keeps one item for it, whichever server the sign-in is with.
                refresh_tokens: Arc::new(move |_: &AccountSettings| host.clone() as Arc<dyn RefreshTokenVault>),
            },
            tasks,
        ))
    }

    // Secrets go to the platform's own store: Credential Manager on Windows.
    #[uniffi::constructor]
    pub fn with_system_secrets(config: HostConfig) -> Result<Arc<Self>, CoreError> {
        let tasks = runtime::tasks()?;
        let secrets = system_secrets(&tasks)?;
        Ok(Self::build(config, secrets, tasks))
    }

    pub fn drivers(&self) -> Vec<DriverInfo> {
        let mut drivers: Vec<DriverInfo> = self
            .registry
            .iter()
            .map(|driver| DriverInfo::of(driver.as_ref()))
            .collect();
        drivers.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        drivers
    }

    pub fn library(&self) -> Result<Arc<ConnectionLibrary>, CoreError> {
        let store = self.store.clone().ok_or_else(no_storage)?;
        Ok(Arc::new(ConnectionLibrary::new(
            store,
            self.vault.clone(),
            self.tasks.clone(),
            self.writes.clone(),
        )))
    }

    // Every caller shares one store. A failed open is tried again on the next call.
    pub async fn history(&self) -> Result<Arc<QueryHistoryStore>, CoreError> {
        let paths = self.paths.clone().ok_or_else(no_storage)?;
        let history = self.history.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            history
                .get_or_try_init(|| QueryHistoryStore::open(paths, tasks))
                .await
                .cloned()
        })
        .await
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

    // Typed secrets come first, then Credential Manager; `keep` is stored once it logs in; no prompter, no SSH asks.
    pub async fn connect_saved(
        &self,
        id: String,
        secrets: ConnectionSecrets,
        keep: ConnectionSecrets,
        prompter: Option<Box<dyn HostPrompter>>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<DatabaseSession>, CoreError> {
        let id = parse_id(&id)?;
        let store = self.store.clone().ok_or_else(no_storage)?;
        let registry = self.registry.clone();
        let connector = self.connector.clone();
        let deadlines = self.deadlines.clone();
        let vault = self.vault.clone();
        let writes = self.writes.clone();
        let tasks = self.tasks.clone();
        let prompter = self.prompter(prompter);
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
            let credentials = Arc::new(Prefilled::new(&saved, vault.clone(), secrets));
            let refreshed = resolve_saved(
                &saved,
                &registry,
                credentials.as_ref(),
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await?;
            let pending = connector
                .establish(refreshed.request, interaction(prompter.as_ref()), cancel.clone())
                .await?;
            if cancel.is_cancelled() {
                let report = pending.discard().await;
                tracing::debug!(
                    ?report,
                    "closed a connection that arrived after its connect was cancelled"
                );
                return Err(CoreError::Cancelled);
            }
            keep_proved_secrets(&store, &vault, &writes, &tasks, &saved, keep.into_typed()).await;
            let session = Session::start(
                pending,
                SessionDeps {
                    connector,
                    credentials,
                    deadlines,
                    tasks: tasks.clone(),
                    prompter,
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
        prompter: Option<Box<dyn HostPrompter>>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<(), CoreError> {
        let id = match record.id.trim() {
            "" => None,
            id => Some(parse_id(id)?),
        };
        let tls = tls_config(&record.tls)?;
        let name = record.name.trim().to_owned();
        let store = self.store.clone();
        let registry = self.registry.clone();
        let connector = self.connector.clone();
        let vault = self.vault.clone();
        let tasks = self.tasks.clone();
        let prompter = self.prompter(prompter);
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            // Over the saved entry, as a save is, so settings the form does not show are tested as Connect uses them.
            let stored = match (id, store) {
                (Some(id), Some(store)) => tasks
                    .spawn_blocking_task(move || store.load_blocking())
                    .await
                    .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??
                    .iter()
                    .find(|saved| saved.id == id)
                    .cloned(),
                _ => None,
            };
            let mut saved = stored.unwrap_or_else(|| blank(id.unwrap_or_else(Uuid::new_v4)));
            apply(&record, &tls, name, saved.group_id, &mut saved);
            let credentials = Prefilled::new(&saved, vault, secrets);
            let refreshed = resolve_saved(
                &saved,
                &registry,
                &credentials,
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await?;
            let pending = connector
                .establish(refreshed.request, interaction(prompter.as_ref()), cancel)
                .await?;
            let report = pending.discard().await;
            tracing::debug!(?report, "closed the test connection");
            Ok(())
        })
        .await
    }
}

impl Core {
    fn build(config: HostConfig, secrets: SystemSecrets, tasks: Tasks) -> Arc<Self> {
        let liveness = LivenessPolicy::DESKTOP;
        let deadlines = Arc::new(DefaultDeadlines::new(liveness));
        let ssh = Arc::new(InProcessSsh::system());
        let services = ConnectServices {
            environment: ConnectEnvironment::new(config.client_version),
            ssh: ssh.clone(),
            liveness,
        };
        let paths = config
            .storage_dir
            .filter(|dir| !dir.trim().is_empty())
            .map(|dir| storage_paths(Path::new(&dir)));
        let store = paths.as_ref().map(ConnectionStore::new);
        Arc::new(Self {
            registry: Arc::new(drivers::registry()),
            connector: Arc::new(DriverConnector::new(services, deadlines.clone())),
            deadlines,
            vault: secrets.vault,
            items: secrets.items,
            refresh_tokens: secrets.refresh_tokens,
            paths,
            store,
            writes: LibraryWrites::default(),
            history: Arc::default(),
            tasks,
            ssh,
        })
    }

    fn prompter(&self, host: Option<Box<dyn HostPrompter>>) -> Option<Arc<dyn CredentialPrompter>> {
        host.map(|host| Arc::new(HostPrompterBridge::new(host, self.tasks.clone())) as Arc<dyn CredentialPrompter>)
    }

    pub fn secret_vault(&self) -> Arc<dyn SecretVault> {
        self.vault.clone()
    }

    pub fn secret_items(&self) -> Arc<dyn SecretItems> {
        self.items.clone()
    }

    pub(crate) fn refresh_tokens(&self) -> RefreshTokens {
        self.refresh_tokens.clone()
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

// Where one sign-in keeps its refresh token, chosen by its settings.
pub(crate) type RefreshTokens = Arc<dyn Fn(&AccountSettings) -> Arc<dyn RefreshTokenVault> + Send + Sync>;

struct SystemSecrets {
    vault: Arc<dyn SecretVault>,
    items: Arc<dyn SecretItems>,
    refresh_tokens: RefreshTokens,
}

#[cfg(windows)]
fn system_secrets(tasks: &Tasks) -> Result<SystemSecrets, CoreError> {
    let manager = Arc::new(crate::credential_manager::CredentialManager::new(
        "TablePro",
        tasks.clone(),
    ));
    Ok(SystemSecrets {
        vault: manager.clone(),
        items: manager.clone(),
        refresh_tokens: Arc::new(move |settings: &AccountSettings| {
            Arc::new(manager.refresh_token(&settings.sign_in_key(), settings.is_production()))
                as Arc<dyn RefreshTokenVault>
        }),
    })
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
    typed: Arc<Mutex<Vec<(SecretKind, SecretString)>>>,
    keyring: KeyringCredentials,
}

impl Prefilled {
    fn new(saved: &SavedConnection, vault: Arc<dyn SecretVault>, secrets: ConnectionSecrets) -> Self {
        let typed = secrets.into_typed();
        Self {
            typed: Arc::new(Mutex::new(typed)),
            keyring: KeyringCredentials::for_saved(vault, saved),
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
        let typed = self.typed.clone();
        let keyring = self.keyring.clone();
        Box::pin(async move {
            let mut request = request;
            let kinds = {
                let held = typed.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                fill(&mut request, &held);
                held.iter().map(|(kind, _)| *kind).collect::<Vec<_>>()
            };
            let refreshed = keyring
                .keeping_session_secrets(&kinds)
                .refresh(request, interaction, demand)
                .await?;
            // The session's reconnect and editor requests are snapshots, so keep later prompt answers here.
            let mut held = typed.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for kind in &refreshed.typed {
                if let Some(secret) = request_secret(&refreshed.request, *kind) {
                    held.retain(|(existing, _)| existing != kind);
                    held.push((*kind, secret.clone()));
                }
            }
            Ok(refreshed)
        })
    }

    fn remember(
        &self,
        saves: Vec<tablepro_core::credentials::SecretSave>,
    ) -> BoxFuture<'static, Vec<(SecretKind, tablepro_core::credentials::SecretError)>> {
        self.keyring.remember(saves)
    }
}

fn request_secret(request: &ConnectRequest, kind: SecretKind) -> Option<&SecretString> {
    let RequestTarget::Network { credentials, ssh, .. } = &request.target else {
        return None;
    };
    match (kind, credentials, ssh.as_ref().map(|ssh| &ssh.auth)) {
        (SecretKind::DatabasePassword, Credentials::Password { password, .. }, _) => Some(password),
        (SecretKind::SshPassword, _, Some(SshAuth::Password { password })) => Some(password),
        (SecretKind::SshPassphrase, _, Some(SshAuth::PrivateKey { passphrase, .. })) => passphrase.as_ref(),
        _ => None,
    }
}

fn fill(request: &mut ConnectRequest, typed: &[(SecretKind, SecretString)]) {
    let RequestTarget::Network { credentials, ssh, .. } = &mut request.target else {
        return;
    };
    for (kind, secret) in typed {
        let secret = secret.clone();
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

// The saved secrets resolve before the login unattended, as the app asks for a missing one itself.
fn interaction(prompter: Option<&Arc<dyn CredentialPrompter>>) -> CredentialInteraction {
    prompter.map_or(CredentialInteraction::Unattended, |prompter| {
        CredentialInteraction::Attended(prompter.clone())
    })
}

fn file_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use async_trait::async_trait;
    use secrecy::ExposeSecret;
    use tablepro_core::credentials::{
        CredentialPrompt, PromptPurpose, PromptReason, PromptReply, SecretError, SecretItem, SecretLookup,
    };
    use tablepro_storage::{SavedSshAuth, SavedSshConfig};

    use super::*;

    #[derive(Default)]
    struct Vault(Mutex<HashMap<(Uuid, SecretKind), SecretString>>);

    #[async_trait]
    impl SecretVault for Vault {
        async fn store(&self, id: Uuid, kind: SecretKind, secret: &SecretString, _: &str) -> Result<(), SecretError> {
            self.0.lock().unwrap().insert((id, kind), secret.clone());
            Ok(())
        }

        async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
            Ok(self
                .0
                .lock()
                .unwrap()
                .get(&(id, kind))
                .cloned()
                .map_or(SecretLookup::NotStored, SecretLookup::Found))
        }

        async fn relabel(&self, _: Uuid, _: SecretKind, _: &str) -> Result<(), SecretError> {
            Ok(())
        }

        async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
            self.0.lock().unwrap().remove(&(id, kind));
            Ok(())
        }

        async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
            self.0.lock().unwrap().retain(|(connection, _), _| *connection != id);
            Ok(())
        }
    }

    struct NoItems;

    #[async_trait]
    impl RefreshTokenVault for NoItems {
        async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
            Ok(None)
        }

        async fn store_refresh_token(&self, _: &SecretString) -> Result<(), SecretError> {
            Ok(())
        }

        async fn delete_refresh_token(&self) -> Result<(), SecretError> {
            Ok(())
        }
    }

    #[async_trait]
    impl SecretItems for NoItems {
        async fn load_item(&self, _: SecretItem) -> Result<Option<SecretString>, SecretError> {
            Ok(None)
        }

        async fn store_item(&self, _: SecretItem, _: &SecretString) -> Result<(), SecretError> {
            Ok(())
        }

        async fn delete_item(&self, _: SecretItem) -> Result<(), SecretError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_test_of_a_saved_connection_uses_the_settings_the_form_does_not_show() {
        let dir = tempfile::tempdir().unwrap();
        let core = Core::build(
            HostConfig {
                client_version: "test".to_owned(),
                storage_dir: Some(dir.path().display().to_string()),
            },
            SystemSecrets {
                vault: Arc::new(Vault::default()),
                items: Arc::new(NoItems),
                refresh_tokens: Arc::new(|_: &AccountSettings| Arc::new(NoItems) as Arc<dyn RefreshTokenVault>),
            },
            runtime::tasks().unwrap(),
        );
        let mut stored = blank(Uuid::new_v4());
        stored.name = "shop".to_owned();
        stored.driver_id = "postgres".to_owned();
        stored.host = "127.0.0.1".to_owned();
        stored.port = 1;
        stored.database = "shop".to_owned();
        stored.username = "app".to_owned();
        stored.tls = tablepro_core::TlsConfig::disabled();
        // An imported file can carry an option the form has no field for; this one PostgreSQL refuses before dialling.
        stored.options.dns_seed_list = true;
        core.store.as_ref().unwrap().upsert_blocking(stored.clone()).unwrap();
        let typed = || ConnectionSecrets {
            database_password: Some(SecretString::from("typed")),
            ..ConnectionSecrets::default()
        };

        let connect = core
            .connect_saved(stored.id.to_string(), typed(), ConnectionSecrets::default(), None, None)
            .await
            .unwrap_err();
        let test = core
            .test_connection(ConnectionRecord::from(&stored), typed(), None, None)
            .await
            .unwrap_err();

        assert_eq!(connect.code(), "config.network_option_unsupported");
        assert_eq!(test.code(), connect.code());
    }

    #[tokio::test]
    async fn a_secret_a_connect_proved_is_kept_only_while_nothing_was_saved_since() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConnectionStore::new(&storage_paths(dir.path()));
        let vault: Arc<dyn SecretVault> = Arc::new(Vault::default());
        let writes = LibraryWrites::default();
        let tasks = runtime::tasks().unwrap();
        let mut proved = blank(Uuid::new_v4());
        proved.driver_id = "postgres".to_owned();
        proved.host = "localhost".to_owned();
        proved.port = 5432;
        proved.username = "app".to_owned();
        proved.ssh = Some(SavedSshConfig {
            host: "staging-bastion".to_owned(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        });
        let typed = || vec![(SecretKind::DatabasePassword, SecretString::from("typed"))];
        let held = |vault: Arc<dyn SecretVault>, id| async move {
            vault
                .load(id, SecretKind::DatabasePassword)
                .await
                .unwrap()
                .found()
                .map(|secret| secret.expose_secret().to_owned())
        };

        keep_proved_secrets(&store, &vault, &writes, &tasks, &proved, typed()).await;
        let deleted = held(vault.clone(), proved.id).await;
        let mut renamed = proved.clone();
        renamed.name = "renamed".to_owned();
        store.upsert_blocking(renamed.clone()).unwrap();
        keep_proved_secrets(&store, &vault, &writes, &tasks, &proved, typed()).await;
        let kept = held(vault.clone(), proved.id).await;
        vault.delete_connection(proved.id).await.unwrap();
        let mut moved = renamed.clone();
        moved.ssh.as_mut().unwrap().host = "prod-bastion".to_owned();
        store.upsert_blocking(moved).unwrap();
        keep_proved_secrets(&store, &vault, &writes, &tasks, &proved, typed()).await;
        let after_move = held(vault.clone(), proved.id).await;
        store.upsert_blocking(renamed).unwrap();
        vault
            .store(
                proved.id,
                SecretKind::DatabasePassword,
                &SecretString::from("saved since"),
                "label",
            )
            .await
            .unwrap();
        keep_proved_secrets(&store, &vault, &writes, &tasks, &proved, typed()).await;
        let after_save = held(vault.clone(), proved.id).await;

        assert_eq!(deleted, None);
        assert_eq!(kept.as_deref(), Some("typed"));
        assert_eq!(after_move, None);
        assert_eq!(after_save.as_deref(), Some("saved since"));
    }

    struct Answer {
        value: &'static str,
        asked: Mutex<Vec<CredentialPrompt>>,
    }

    impl CredentialPrompter for Answer {
        fn prompt(&self, prompt: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
            self.asked.lock().unwrap().push(prompt);
            let value = self.value;
            Box::pin(async move {
                PromptReply::Submitted {
                    values: vec![SecretString::from(value)],
                    remember: false,
                }
            })
        }
    }

    fn saved(kind: SecretKind) -> SavedConnection {
        let mut saved = blank(Uuid::new_v4());
        saved.driver_id = "postgres".to_owned();
        saved.host = "db.internal".to_owned();
        saved.port = 5432;
        saved.database = "shop".to_owned();
        saved.username = "app".to_owned();
        saved.ssh = Some(SavedSshConfig {
            host: "bastion.internal".to_owned(),
            port: Some(22),
            username: Some("deploy".to_owned()),
            jump_hosts: Vec::new(),
            auth: match kind {
                SecretKind::SshPassphrase => SavedSshAuth::PrivateKey {
                    path: Some(PathBuf::from("/keys/id_ed25519")),
                    has_passphrase: true,
                },
                _ => SavedSshAuth::Password,
            },
        });
        saved
    }

    fn secrets(value: &str) -> ConnectionSecrets {
        ConnectionSecrets {
            database_password: Some(SecretString::from(value)),
            ssh_password: Some(SecretString::from(value)),
            ssh_passphrase: Some(SecretString::from(value)),
        }
    }

    fn value(request: &ConnectRequest, kind: SecretKind) -> &str {
        let RequestTarget::Network {
            credentials: Credentials::Password { password, .. },
            ssh: Some(ssh),
            ..
        } = &request.target
        else {
            panic!("expected a password connection through SSH");
        };
        match (kind, &ssh.auth) {
            (SecretKind::DatabasePassword, _) => password.expose_secret(),
            (SecretKind::SshPassword, SshAuth::Password { password }) => password.expose_secret(),
            (
                SecretKind::SshPassphrase,
                SshAuth::PrivateKey {
                    passphrase: Some(passphrase),
                    ..
                },
            ) => passphrase.expose_secret(),
            _ => panic!("secret kind does not match the SSH method"),
        }
    }

    #[tokio::test]
    async fn explicitly_empty_form_secrets_survive_initial_resolution_and_reconnect() {
        for kind in SecretKind::ALL {
            let saved = saved(kind);
            let vault = Arc::new(Vault::default());
            vault
                .store(saved.id, kind, &SecretString::from("stored before"), "saved")
                .await
                .unwrap();
            let credentials = Prefilled::new(&saved, vault, secrets(""));
            let first = resolve_saved(
                &saved,
                &drivers::registry(),
                &credentials,
                CredentialInteraction::Unattended,
                CredentialDemand::default(),
            )
            .await
            .unwrap();
            assert_eq!(value(&first.request, kind), "");

            let reconnect = credentials
                .refresh(
                    first.request.for_reconnect(),
                    CredentialInteraction::Unattended,
                    CredentialDemand::default(),
                )
                .await
                .unwrap();
            assert_eq!(value(&reconnect.request, kind), "");
        }
    }

    #[tokio::test]
    async fn a_reentered_secret_replaces_the_form_value_in_later_refreshes() {
        for kind in SecretKind::ALL {
            for replacement in ["corrected", ""] {
                let saved = saved(kind);
                let credentials = Prefilled::new(&saved, Arc::new(Vault::default()), secrets("original"));
                let first = resolve_saved(
                    &saved,
                    &drivers::registry(),
                    &credentials,
                    CredentialInteraction::Unattended,
                    CredentialDemand::default(),
                )
                .await
                .unwrap();
                assert_eq!(value(&first.request, kind), "original");
                let answer = Arc::new(Answer {
                    value: replacement,
                    asked: Mutex::new(Vec::new()),
                });

                let corrected = credentials
                    .refresh(
                        first.request.for_reconnect(),
                        CredentialInteraction::Attended(answer.clone()),
                        CredentialDemand::reenter(kind),
                    )
                    .await
                    .unwrap();
                assert_eq!(value(&corrected.request, kind), replacement);
                assert_eq!(corrected.typed, [kind]);
                assert!(corrected.remember.is_empty());
                {
                    let asked = answer.asked.lock().unwrap();
                    assert_eq!(asked.len(), 1);
                    assert!(matches!(
                        asked[0].purpose,
                        PromptPurpose::DatabasePassword {
                            reason: PromptReason::Rejected
                        } | PromptPurpose::SshPassword {
                            reason: PromptReason::Rejected
                        } | PromptPurpose::SshPassphrase {
                            reason: PromptReason::Rejected,
                            ..
                        }
                    ));
                }

                let reconnect = credentials
                    .refresh(
                        first.request.for_reconnect(),
                        CredentialInteraction::Unattended,
                        CredentialDemand::default(),
                    )
                    .await
                    .unwrap();
                assert_eq!(value(&reconnect.request, kind), replacement);
                assert_eq!(answer.asked.lock().unwrap().len(), 1);
            }
        }
    }
}
