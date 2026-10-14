use std::sync::Arc;

use tablepro_core::LivenessPolicy;
use tablepro_session::fakes::{FakeConnector, FakeCredentialSource, FakeEstablish};
use tablepro_session::operation::DefaultDeadlines;
use tablepro_session::runtime::Tasks;
use tablepro_session::{ConnectRequest, Session, SessionDeps};
use tablepro_test_support::{ConnectionScript, FakeConnection};

/// A session over a fake connection, and what each reconnect gets.
pub(crate) struct FakeSession {
    pub session: Arc<Session>,
    pub connection: Arc<FakeConnection>,
    /// Every connection a reconnect built, in order.
    pub connector: FakeConnector,
}

impl FakeSession {
    pub(crate) fn start(
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        tasks: Tasks,
    ) -> Self {
        let request = FakeConnector::request().expect("a request");
        Self::start_for(request, script, reconnects, tasks)
    }

    /// A session opened by `request`, which decides what the network has
    /// to reach for it.
    pub(crate) fn start_for(
        request: ConnectRequest,
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
        tasks: Tasks,
    ) -> Self {
        let (pending, connection) = FakeConnector::pending_session(request, script);
        let connector = FakeConnector::new(reconnects);
        let session = Session::start(
            pending,
            SessionDeps {
                connector: Arc::new(connector.clone()),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks,
                prompter: None,
            },
        );
        Self {
            session,
            connection,
            connector,
        }
    }

    /// The connection the last reconnect put in place.
    pub(crate) fn replacement(&self) -> Arc<FakeConnection> {
        self.connector.connections().pop().expect("a reconnect's connection")
    }
}
