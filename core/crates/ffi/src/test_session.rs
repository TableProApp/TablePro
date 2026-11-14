use std::sync::Arc;

use tablepro_core::LivenessPolicy;
use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
use tablepro_session::runtime::Tasks;
use tablepro_session::{DefaultDeadlines, Session, SessionDeps};
use tablepro_test_support::ConnectionScript;

// A session of a network server whose connection answers from `script`.
#[expect(
    clippy::disallowed_methods,
    reason = "a test is already inside its own runtime; production code takes the handle from AppRuntime"
)]
pub(crate) fn started(script: ConnectionScript) -> (Arc<Session>, Tasks) {
    let tasks = Tasks::new(tokio::runtime::Handle::current());
    let request = FakeConnector::network_request("db.example", 5432).expect("a request");
    let (pending, _) = FakeConnector::pending_session(request, script);
    let session = Session::start(
        pending,
        SessionDeps {
            connector: Arc::new(FakeConnector::new([])),
            credentials: Arc::new(FakeCredentialSource::new()),
            deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            tasks: tasks.clone(),
            prompter: None,
        },
    );
    (session, tasks)
}
