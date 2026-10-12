use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use futures::future::BoxFuture;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{ConfigError, FileEndpoint, LivenessPolicy, WorkspaceSettings};
use tablepro_test_support::{ConnectionScript, FakeConnection, FakeDriver};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::connect::{ConnectError, ConnectRequest, ConnectionMetadata, Connector, PendingSession, RequestTarget};
use crate::link::EstablishedConnection;

/// One scripted `establish` result.
#[derive(Debug, Clone)]
pub enum FakeEstablish {
    Connect(ConnectionScript),
    Fail(ConnectError),
    /// Connects after `after` whatever the cancel token says, the way a
    /// driver blocked in a C call does.
    Late {
        after: Duration,
        script: ConnectionScript,
    },
    /// Never connects; ends with `Cancelled` when cancelled.
    UntilCancelled,
}

/// What one `establish` call was asked.
#[derive(Debug, Clone)]
pub struct EstablishCall {
    pub at: Instant,
    pub request: ConnectRequest,
    pub attended: bool,
}

#[derive(Default)]
struct State {
    replies: VecDeque<FakeEstablish>,
    otherwise: Option<FakeEstablish>,
    calls: Vec<EstablishCall>,
    connections: Vec<Arc<FakeConnection>>,
}

/// A `Connector` that answers from a script and builds sessions over
/// `FakeConnection`s, so tests see what each attempt left behind.
#[derive(Clone, Default)]
pub struct FakeConnector {
    state: Arc<Mutex<State>>,
}

impl FakeConnector {
    pub fn new(replies: impl IntoIterator<Item = FakeEstablish>) -> Self {
        let connector = Self::default();
        connector.lock().replies.extend(replies);
        connector
    }

    /// The reply once the scripted ones run out.
    pub fn always(self, reply: FakeEstablish) -> Self {
        self.lock().otherwise = Some(reply);
        self
    }

    pub fn calls(&self) -> Vec<EstablishCall> {
        self.lock().calls.clone()
    }

    /// Every connection an attempt built, in order, including ones that
    /// finished too late to be adopted.
    pub fn connections(&self) -> Vec<Arc<FakeConnection>> {
        self.lock().connections.clone()
    }

    /// A request for a file the fake driver opens, for tests that need
    /// a request and do not care where it goes.
    pub fn request() -> Result<ConnectRequest, ConfigError> {
        Ok(ConnectRequest {
            metadata: ConnectionMetadata {
                id: Uuid::new_v4(),
                name: "Fake".to_owned(),
                driver_id: "fake".to_owned(),
            },
            driver: Arc::new(FakeDriver::connecting(
                &FakeDriver::FILE_CAPABILITIES,
                ConnectionScript::default(),
            )),
            target: RequestTarget::File(FileEndpoint::open_existing(PathBuf::from("/fake.db"))?),
            workspace_settings: WorkspaceSettings::workspace(false),
        })
    }

    /// A pending session over a new fake connection, without a connector.
    pub fn pending_session(request: ConnectRequest, script: ConnectionScript) -> (PendingSession, Arc<FakeConnection>) {
        let connection = Arc::new(FakeConnection::new(script));
        let pending = PendingSession::new(
            request,
            EstablishedConnection {
                connection: connection.clone(),
                ssh_session: None,
            },
            Vec::new(),
            Vec::new(),
            LivenessPolicy::DESKTOP.close_timeout,
        );
        (pending, connection)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn adopt(&self, request: ConnectRequest, script: ConnectionScript) -> PendingSession {
        let (pending, connection) = Self::pending_session(request, script);
        self.lock().connections.push(connection);
        pending
    }
}

impl Connector for FakeConnector {
    fn establish(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> BoxFuture<'static, Result<PendingSession, ConnectError>> {
        let reply = {
            let mut state = self.lock();
            state.calls.push(EstablishCall {
                at: Instant::now(),
                request: request.clone(),
                attended: matches!(interaction, CredentialInteraction::Attended(_)),
            });
            state.replies.pop_front().or_else(|| state.otherwise.clone())
        };
        let connector = self.clone();
        Box::pin(async move {
            match reply {
                Some(FakeEstablish::Connect(script)) => Ok(connector.adopt(request, script)),
                Some(FakeEstablish::Fail(error)) => Err(error),
                Some(FakeEstablish::Late { after, script }) => {
                    tokio::time::sleep(after).await;
                    Ok(connector.adopt(request, script))
                }
                Some(FakeEstablish::UntilCancelled) => {
                    cancel.cancelled().await;
                    Err(ConnectError::Cancelled)
                }
                None => Err(ConnectError::UnknownDriver(
                    "FakeConnector has no scripted establish result".to_owned(),
                )),
            }
        })
    }
}

impl std::fmt::Debug for FakeConnector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = self.lock();
        f.debug_struct("FakeConnector")
            .field("queued", &state.replies.len())
            .field("calls", &state.calls.len())
            .finish_non_exhaustive()
    }
}
