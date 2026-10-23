use std::cell::RefCell;
use std::rc::{Rc, Weak};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use gio::prelude::SettingsExt;
use gtk4::prelude::ObjectExt;
use secrecy::{ExposeSecret, SecretString};
use tablepro_mcp::{AccessToken, McpServer, ToolContext, TokenVault};
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;
use tokio::sync::{Mutex, watch};

use super::mcp_status::{McpFailure, McpStatus};

/// Runs the MCP server while its preference is on, on the port the
/// preferences name. GTK-thread only; the server runs on `Tasks`.
#[derive(Clone)]
pub struct McpService {
    inner: Rc<Inner>,
}

struct Inner {
    settings: Rc<AppSettings>,
    tasks: Tasks,
    tokens: Arc<dyn TokenVault>,
    context: ToolContext,
    status: watch::Sender<McpStatus>,
    // Every start, stop and token change takes this lock in turn, so a
    // stop has freed the port before the next start binds it.
    slot: Arc<Mutex<Option<Live>>>,
    generation: Arc<AtomicU64>,
    token: RefCell<Option<AccessToken>>,
    handlers: RefCell<Vec<glib::SignalHandlerId>>,
}

struct Live {
    server: McpServer,
}

type Started = Option<Result<(u16, AccessToken), McpFailure>>;

impl McpService {
    pub fn start(settings: Rc<AppSettings>, tasks: Tasks, tokens: Arc<dyn TokenVault>, context: ToolContext) -> Self {
        let service = Self {
            inner: Rc::new(Inner {
                settings,
                tasks,
                tokens,
                context,
                status: watch::channel(McpStatus::Off).0,
                slot: Arc::new(Mutex::new(None)),
                generation: Arc::new(AtomicU64::new(0)),
                token: RefCell::new(None),
                handlers: RefCell::new(Vec::new()),
            }),
        };
        let gio = service.inner.settings.gio().clone();
        for key in [keys::MCP_SERVER_ENABLED, keys::MCP_SERVER_PORT] {
            let weak = Rc::downgrade(&service.inner);
            let handler = gio.connect_changed(Some(key), move |_, _| {
                if let Some(inner) = weak.upgrade() {
                    Self { inner }.apply();
                }
            });
            service.inner.handlers.borrow_mut().push(handler);
        }
        service.apply();
        service
    }

    pub fn status(&self) -> watch::Receiver<McpStatus> {
        self.inner.status.subscribe()
    }

    /// The token clients present, while the server runs.
    pub fn token(&self) -> Option<SecretString> {
        self.inner
            .token
            .borrow()
            .as_ref()
            .map(|token| SecretString::from(token.secret().expose_secret().to_owned()))
    }

    /// Start again with the preferences as they are, after a failure.
    pub fn retry(&self) {
        self.apply();
    }

    /// Store a new token and hand it to the running server, which turns
    /// the old one away from the next request.
    pub async fn regenerate_token(&self) -> Result<(), McpFailure> {
        let (slot, tokens) = (self.inner.slot.clone(), self.inner.tokens.clone());
        let replacing = self.inner.tasks.spawn_task(async move {
            let live = slot.lock().await;
            let token = tablepro_mcp::replace_token(&*tokens).await?;
            if let Some(live) = live.as_ref() {
                live.server.replace_token(token.clone());
            }
            Ok::<_, McpFailure>(token)
        });
        let weak = Rc::downgrade(&self.inner);
        let token = replacing.await.map_err(|failure| McpFailure::Interrupted(failure.to_string()))??;
        if let Some(inner) = weak.upgrade()
            && inner.status.borrow().port().is_some()
        {
            inner.token.replace(Some(token));
        }
        Ok(())
    }

    /// Stop for good, as the application quits.
    pub fn stop(&self) {
        for handler in self.inner.handlers.take() {
            self.inner.settings.gio().disconnect(handler);
        }
        self.inner.generation.fetch_add(1, Ordering::SeqCst);
        self.inner.token.replace(None);
        self.inner.status.send_replace(McpStatus::Off);
        let slot = self.inner.slot.clone();
        drop(self.inner.tasks.spawn_task(async move {
            if let Some(live) = slot.lock().await.take() {
                live.server.shutdown().await;
            }
        }));
    }

    fn apply(&self) {
        let inner = &self.inner;
        let generation = inner.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let enabled = inner.settings.mcp_server_enabled();
        let port = inner.settings.mcp_server_port();
        inner.token.replace(None);
        inner.status.send_replace(match enabled {
            true => McpStatus::Starting,
            false => McpStatus::Off,
        });
        let work = restart(
            inner.slot.clone(),
            inner.generation.clone(),
            generation,
            enabled.then_some(port),
            inner.tokens.clone(),
            inner.context.clone(),
            inner.tasks.clone(),
        );
        let weak = Rc::downgrade(inner);
        drop(crate::runtime::spawn_and_deliver(&inner.tasks, work, move |outcome| {
            deliver(&weak, generation, port, outcome);
        }));
    }
}

async fn restart(
    slot: Arc<Mutex<Option<Live>>>,
    current: Arc<AtomicU64>,
    generation: u64,
    port: Option<u16>,
    tokens: Arc<dyn TokenVault>,
    context: ToolContext,
    tasks: Tasks,
) -> Started {
    let mut live = slot.lock().await;
    if let Some(previous) = live.take() {
        previous.server.shutdown().await;
    }
    // A later change is queued behind this one and decides for itself.
    let port = port.filter(|_| current.load(Ordering::SeqCst) == generation)?;
    let started = async {
        let token = tablepro_mcp::obtain_token(&*tokens).await?;
        let server = McpServer::start(port, token.clone(), context, crate::config::VERSION, &tasks).await?;
        Ok::<_, McpFailure>((server, token))
    }
    .await;
    Some(started.map(|(server, token)| {
        let bound = server.address().port();
        *live = Some(Live { server });
        (bound, token)
    }))
}

fn deliver(
    inner: &Weak<Inner>,
    generation: u64,
    port: u16,
    outcome: Result<Started, tablepro_session::runtime::TaskFailure>,
) {
    let Some(inner) = inner.upgrade() else {
        return;
    };
    if inner.generation.load(Ordering::SeqCst) != generation {
        return;
    }
    match outcome {
        Ok(None) => {}
        Ok(Some(Ok((port, token)))) => {
            inner.token.replace(Some(token));
            inner.status.send_replace(McpStatus::Running { port });
        }
        Ok(Some(Err(failure))) => {
            tracing::warn!(?failure, port, "the MCP server did not start");
            inner.status.send_replace(McpStatus::Failed(failure));
        }
        Err(failure) => {
            tracing::warn!(%failure, port, "the MCP server's start was interrupted");
            inner
                .status
                .send_replace(McpStatus::Failed(McpFailure::Interrupted(failure.to_string())));
        }
    }
}

impl std::fmt::Debug for McpService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpService")
            .field("status", &*self.inner.status.borrow())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Mutex as StdMutex;
    use std::time::Duration;

    use async_trait::async_trait;
    use tablepro_core::credentials::SecretError;
    use tablepro_core::dialect::SqlDialect;
    use tablepro_mcp::{McpHost, OpenOutcome, WriteApproval};
    use tablepro_session::Session;
    use tablepro_storage::query_history::NewEntry;
    use tablepro_storage::{ConnectionStore, SavedConnection, StoragePaths};
    use uuid::Uuid;

    use super::*;
    use crate::test_support::{MemorySettings, test_runtime, wait_until};

    const WAIT: Duration = Duration::from_secs(10);

    #[derive(Default)]
    pub(crate) struct MemoryTokens(pub(crate) StdMutex<Option<String>>);

    #[async_trait]
    impl TokenVault for MemoryTokens {
        async fn load_token(&self) -> Result<Option<SecretString>, SecretError> {
            Ok(self.0.lock().expect("tokens").clone().map(SecretString::from))
        }

        async fn store_token(&self, token: &SecretString) -> Result<(), SecretError> {
            *self.0.lock().expect("tokens") = Some(token.expose_secret().to_owned());
            Ok(())
        }
    }

    struct LockedTokens;

    #[async_trait]
    impl TokenVault for LockedTokens {
        async fn load_token(&self) -> Result<Option<SecretString>, SecretError> {
            Err(SecretError::Locked)
        }

        async fn store_token(&self, _token: &SecretString) -> Result<(), SecretError> {
            Err(SecretError::Locked)
        }
    }

    pub(crate) struct NoWindows;

    #[async_trait]
    impl McpHost for NoWindows {
        async fn session(&self, _id: Uuid) -> Option<Arc<Session>> {
            None
        }

        async fn open_connections(&self) -> Vec<Uuid> {
            Vec::new()
        }

        async fn open(&self, _connection: SavedConnection) -> OpenOutcome {
            OpenOutcome::Closed
        }

        async fn approve(&self, _approval: WriteApproval) -> bool {
            false
        }

        async fn record(&self, _entry: NewEntry, _dialect: Arc<dyn SqlDialect>) {}
    }

    pub(crate) fn context(root: &std::path::Path) -> ToolContext {
        ToolContext {
            host: Arc::new(NoWindows),
            connections: ConnectionStore::new(&StoragePaths::under(root, "tablepro-test", "app.tablepro.Test")),
        }
    }

    /// A port nothing listens on now, in the range the schema allows.
    pub(crate) fn free_port() -> u16 {
        std::net::TcpListener::bind(("127.0.0.1", 0))
            .and_then(|listener| listener.local_addr())
            .map(|address| address.port())
            .expect("a free port")
    }

    fn status(service: &McpService) -> McpStatus {
        service.status().borrow().clone()
    }

    #[gtk4::test]
    fn the_server_runs_only_while_the_preference_is_on() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let tokens = Arc::new(MemoryTokens::default());
        let port = free_port();
        settings.get().set_mcp_server_port(port).expect("the port");
        let service = McpService::start(settings.get().clone(), runtime.tasks(), tokens.clone(), context(root.path()));

        assert_eq!(status(&service), McpStatus::Off);
        settings.get().set_mcp_server_enabled(true).expect("the switch");
        wait_until(WAIT, || status(&service) == McpStatus::Running { port }).expect("the server to run");
        let stored = tokens.0.lock().expect("tokens").clone();
        assert_eq!(service.token().map(|token| token.expose_secret().to_owned()), stored);
        assert!(std::net::TcpListener::bind(("127.0.0.1", port)).is_err());

        settings.get().set_mcp_server_enabled(false).expect("the switch");
        assert_eq!(status(&service), McpStatus::Off);
        assert!(service.token().is_none());
        wait_until(WAIT, || std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()).expect("the port freed");
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_new_port_moves_the_server_and_a_taken_one_says_so() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let first = free_port();
        settings.get().set_mcp_server_port(first).expect("the port");
        settings.get().set_mcp_server_enabled(true).expect("the switch");
        let service = McpService::start(
            settings.get().clone(),
            runtime.tasks(),
            Arc::new(MemoryTokens::default()),
            context(root.path()),
        );
        wait_until(WAIT, || status(&service) == McpStatus::Running { port: first }).expect("the server to run");
        let taken = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("a listener");
        let taken_port = taken.local_addr().expect("its address").port();

        settings.get().set_mcp_server_port(taken_port).expect("the port");

        wait_until(WAIT, || {
            status(&service) == McpStatus::Failed(McpFailure::PortInUse(taken_port))
        })
        .expect("the taken port reported");
        wait_until(WAIT, || std::net::TcpListener::bind(("127.0.0.1", first)).is_ok()).expect("the old port freed");
        drop(taken);
        service.retry();
        wait_until(WAIT, || status(&service) == McpStatus::Running { port: taken_port }).expect("the retry to run");
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_locked_keyring_keeps_the_server_from_starting() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        settings.get().set_mcp_server_port(free_port()).expect("the port");
        settings.get().set_mcp_server_enabled(true).expect("the switch");

        let service = McpService::start(
            settings.get().clone(),
            runtime.tasks(),
            Arc::new(LockedTokens),
            context(root.path()),
        );

        wait_until(WAIT, || {
            status(&service) == McpStatus::Failed(McpFailure::Keyring(SecretError::Locked))
        })
        .expect("the keyring failure reported");
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_regenerated_token_replaces_the_one_shown_and_stored() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let tokens = Arc::new(MemoryTokens::default());
        let port = free_port();
        settings.get().set_mcp_server_port(port).expect("the port");
        settings.get().set_mcp_server_enabled(true).expect("the switch");
        let service = McpService::start(settings.get().clone(), runtime.tasks(), tokens.clone(), context(root.path()));
        wait_until(WAIT, || status(&service) == McpStatus::Running { port }).expect("the server to run");
        let before = service.token().map(|token| token.expose_secret().to_owned());

        let done = Rc::new(RefCell::new(None));
        let (sink, regenerating) = (done.clone(), service.clone());
        glib::spawn_future_local(async move {
            sink.replace(Some(regenerating.regenerate_token().await));
        });
        wait_until(WAIT, || done.borrow().is_some()).expect("the new token");

        let after = service.token().map(|token| token.expose_secret().to_owned());
        assert!(matches!(*done.borrow(), Some(Ok(()))));
        assert_ne!(before, after);
        assert_eq!(after, tokens.0.lock().expect("tokens").clone());
        runtime.shutdown();
    }
}
