use std::sync::{Arc, Mutex, PoisonError};
use std::time::UNIX_EPOCH;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::credentials::{SecretError, SecretItems};
use tablepro_mcp::{AccessToken, McpServer, ObtainError, SeenClient, StartError, TokenVault, ToolContext};
use tablepro_session::runtime::Tasks;
use tokio::sync::watch;
use tokio_util::task::AbortOnDropHandle;

use crate::error::{BoxedErrorInfo, CoreError};
use crate::runtime::on_runtime;

// Called on a runtime thread; it only schedules a read of `status` and `seen_clients` on the app's own thread.
#[uniffi::export(callback_interface)]
pub trait McpListener: Send + Sync {
    fn changed(&self);
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum McpStatusTag {
    Off,
    Starting { port: u16 },
    Running { port: u16 },
    // `mcp.port_in_use`, `mcp.listen_failed`, `mcp.no_randomness`, `mcp.interrupted`, or the token's `secret.*`.
    Failed { port: u16, error: BoxedErrorInfo },
}

// A client as it named itself the last time it started a session with the running server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeenClientInfo {
    pub name: String,
    pub title: Option<String>,
    pub version: String,
    pub seen_at_ms: i64,
}

// The MCP server while the app's setting has it on. One per app; dropping it stops the server.
#[derive(uniffi::Object)]
pub struct McpService {
    inner: Arc<Inner>,
}

struct Inner {
    tasks: Tasks,
    tokens: Arc<dyn TokenVault>,
    context: ToolContext,
    version: String,
    listener: Arc<dyn McpListener>,
    shown: Mutex<Shown>,
    // Taken by every start, stop and token change in turn, so a stop frees the port before the next start binds it.
    live: Arc<tokio::sync::Mutex<Option<McpServer>>>,
}

// One lock over the generation and what it shows, so a start that settles late never shows over a later change.
struct Shown {
    generation: u64,
    status: McpStatusTag,
    seen: Vec<SeenClientInfo>,
    following: Option<AbortOnDropHandle<()>>,
}

impl McpService {
    pub(crate) fn new(
        tasks: Tasks,
        items: Arc<dyn SecretItems>,
        context: ToolContext,
        version: String,
        listener: Arc<dyn McpListener>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                tasks,
                tokens: Arc::new(StoredTokens(items)),
                context,
                version,
                listener,
                shown: Mutex::new(Shown {
                    generation: 0,
                    status: McpStatusTag::Off,
                    seen: Vec::new(),
                    following: None,
                }),
                live: Arc::default(),
            }),
        }
    }
}

#[uniffi::export]
impl McpService {
    // Called again on each change of the setting, and to try again; returns at once and the listener hears the rest.
    pub fn apply(&self, enabled: bool, port: u16) {
        let inner = self.inner.clone();
        let generation = inner.next(match enabled {
            true => McpStatusTag::Starting { port },
            false => McpStatusTag::Off,
        });
        let tasks = inner.tasks.clone();
        drop(tasks.spawn_task(async move {
            let started = inner.restart(generation, enabled.then_some(port)).await;
            inner.settle(generation, port, started);
        }));
    }

    pub fn status(&self) -> McpStatusTag {
        self.inner.lock().status.clone()
    }

    // Each client that started a session since the server last started, the latest last.
    pub fn seen_clients(&self) -> Vec<SeenClientInfo> {
        self.inner.lock().seen.clone()
    }

    // Read from the secret store, or made and kept there first, so a client set up once keeps working.
    pub async fn access_token(&self) -> Result<SecretString, CoreError> {
        let inner = self.inner.clone();
        on_runtime(&self.inner.tasks, async move {
            let _serialized = inner.live.lock().await;
            let token = tablepro_mcp::obtain_token(inner.tokens.as_ref())
                .await
                .map_err(obtain_failure)?;
            Ok(token.secret().clone())
        })
        .await
    }

    // A new token, kept before it is used; the running server refuses the old one from the next request.
    pub async fn regenerate_token(&self) -> Result<(), CoreError> {
        let inner = self.inner.clone();
        on_runtime(&self.inner.tasks, async move {
            let live = inner.live.lock().await;
            let token = tablepro_mcp::replace_token(inner.tokens.as_ref())
                .await
                .map_err(obtain_failure)?;
            if let Some(server) = live.as_ref() {
                server.replace_token(token);
            }
            Ok(())
        })
        .await
    }

    // For good, as the app quits; returns once the port is free.
    pub async fn stop(&self) {
        let inner = self.inner.clone();
        inner.next(McpStatusTag::Off);
        let stopping = on_runtime(&self.inner.tasks, async move {
            if let Some(server) = inner.live.lock().await.take() {
                server.shutdown().await;
            }
            Ok(())
        });
        if let Err(error) = stopping.await {
            tracing::warn!(%error, "the MCP server's stop was interrupted");
        }
    }
}

impl Drop for McpService {
    fn drop(&mut self) {
        self.inner.lock().generation += 1;
        let live = self.inner.live.clone();
        drop(self.inner.tasks.spawn_task(async move {
            if let Some(server) = live.lock().await.take() {
                server.shutdown().await;
            }
        }));
    }
}

type Started = Option<Result<(u16, watch::Receiver<Vec<SeenClient>>), CoreError>>;

impl Inner {
    fn lock(&self) -> std::sync::MutexGuard<'_, Shown> {
        self.shown.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // What a change shows until its own start settles; a stopped or moved server's clients are forgotten with it.
    fn next(self: &Arc<Self>, status: McpStatusTag) -> u64 {
        let generation = {
            let mut shown = self.lock();
            shown.generation += 1;
            shown.status = status;
            shown.seen.clear();
            shown.following = None;
            shown.generation
        };
        self.signal();
        generation
    }

    fn current(&self, generation: u64) -> bool {
        self.lock().generation == generation
    }

    fn signal(self: &Arc<Self>) {
        let listener = self.listener.clone();
        drop(self.tasks.spawn_task(async move { listener.changed() }));
    }

    async fn restart(&self, generation: u64, port: Option<u16>) -> Started {
        let mut live = self.live.lock().await;
        // Tasks reach the lock out of order; a later change decides for itself, and may have started the live server.
        if !self.current(generation) {
            return None;
        }
        if let Some(previous) = live.take() {
            previous.shutdown().await;
        }
        let port = port?;
        let started = async {
            let token: AccessToken = tablepro_mcp::obtain_token(self.tokens.as_ref())
                .await
                .map_err(obtain_failure)?;
            McpServer::start(port, token, self.context.clone(), &self.version, &self.tasks)
                .await
                .map_err(start_failure)
        }
        .await;
        Some(started.map(|server| {
            let bound = server.address().port();
            let sightings = server.seen_clients();
            *live = Some(server);
            (bound, sightings)
        }))
    }

    fn settle(self: &Arc<Self>, generation: u64, port: u16, started: Started) {
        let (status, following) = match started {
            None => return,
            Some(Ok((bound, sightings))) => (
                McpStatusTag::Running { port: bound },
                Some(self.follow(generation, sightings)),
            ),
            Some(Err(error)) => {
                tracing::warn!(%error, port, "the MCP server did not start");
                (
                    McpStatusTag::Failed {
                        port,
                        error: error.into_info(),
                    },
                    None,
                )
            }
        };
        {
            let mut shown = self.lock();
            if shown.generation != generation {
                return;
            }
            shown.status = status;
            shown.following = following;
        }
        self.signal();
    }

    // Ends with the server, whose sender then drops, or when a later status replaces it.
    fn follow(
        self: &Arc<Self>,
        generation: u64,
        mut sightings: watch::Receiver<Vec<SeenClient>>,
    ) -> AbortOnDropHandle<()> {
        let weak = Arc::downgrade(self);
        self.tasks.spawn_owned(async move {
            while sightings.changed().await.is_ok() {
                let clients: Vec<SeenClientInfo> = sightings.borrow_and_update().iter().map(seen).collect();
                let Some(inner) = weak.upgrade() else {
                    return;
                };
                {
                    let mut shown = inner.lock();
                    if shown.generation != generation {
                        return;
                    }
                    shown.seen = clients;
                }
                inner.listener.changed();
            }
        })
    }
}

fn seen(client: &SeenClient) -> SeenClientInfo {
    SeenClientInfo {
        name: client.name.clone(),
        title: client.title.clone(),
        version: client.version.clone(),
        seen_at_ms: client
            .seen_at
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| i64::try_from(since.as_millis()).unwrap_or(i64::MAX)),
    }
}

fn obtain_failure(error: ObtainError) -> CoreError {
    match error {
        ObtainError::Keyring(error) => secret_failure(&error),
        ObtainError::Random(error) => CoreError::failed("mcp.no_randomness", error.to_string()),
    }
}

pub(crate) fn secret_failure(error: &SecretError) -> CoreError {
    CoreError::failed(error.code(), error.to_string())
}

fn start_failure(error: StartError) -> CoreError {
    match error {
        StartError::PortInUse(_) => CoreError::failed("mcp.port_in_use", error.to_string()),
        StartError::Listen { .. } => CoreError::failed("mcp.listen_failed", error.to_string()),
    }
}

// The token as the core's secret store keeps it, as `SecretItem::McpToken`.
struct StoredTokens(Arc<dyn SecretItems>);

#[async_trait]
impl TokenVault for StoredTokens {
    async fn load_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.0.load_item(tablepro_core::credentials::SecretItem::McpToken).await
    }

    async fn store_token(&self, token: &SecretString) -> Result<(), SecretError> {
        self.0
            .store_item(tablepro_core::credentials::SecretItem::McpToken, token)
            .await
    }
}

impl std::fmt::Debug for McpService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpService")
            .field("status", &self.inner.lock().status)
            .finish_non_exhaustive()
    }
}
