use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bson::{Document, doc};
use mongodb::{Client, ClientSession};
use tablepro_core::sql_syntax::mongo::{ShellStatement, parse_bound_statement};
use tablepro_core::statement::Statement;
use tablepro_core::{CallResource, DriverError, EngineStop, LossPhase, StopDelivery, StopScope};
use tokio::time::Instant;

use crate::endpoint::MongoEndpoint;
use crate::errors::stopped_by_kill;
use crate::shell_command::{Plan, plan};

/// The stop of one call: `killSessions` for the logical session the call
/// runs in, which ends the operation that session has on the server and
/// closes its cursors. Every call has a session of its own, so the stop
/// names the call and nothing else.
pub(crate) struct SessionKill {
    /// The client the session belongs to, which sends the kill on a
    /// connection of its own, and the session's id.
    armed: Mutex<Option<(Client, Document)>>,
    sent: Mutex<KillState>,
}

/// How far a kill got, which says whether the route to the server still
/// carries anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KillState {
    NotSent,
    /// Sent with no answer yet, or none before the call was given up.
    Unanswered,
    Answered,
}

impl SessionKill {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            armed: Mutex::new(None),
            sent: Mutex::new(KillState::NotSent),
        })
    }

    pub(crate) fn state(&self) -> KillState {
        *self.sent.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn mark(&self, state: KillState) {
        *self.sent.lock().unwrap_or_else(PoisonError::into_inner) = state;
    }

    /// Name the session the stop ends, once the call has one.
    pub(crate) fn arm(&self, client: &Client, session: &ClientSession) {
        *self.armed.lock().unwrap_or_else(PoisonError::into_inner) = Some((client.clone(), session.id().clone()));
    }

    pub(crate) async fn kill(&self) -> Result<(), DriverError> {
        let armed = self.armed.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some((client, session)) = armed else {
            return Ok(());
        };
        self.mark(KillState::Unanswered);
        let answered = client
            .database("admin")
            .run_command(doc! { "killSessions": [session] })
            .await;
        // Any reply, a refusal included, came back over the route.
        let replied = match &answered {
            Ok(_) => true,
            Err(error) => matches!(error.kind.as_ref(), mongodb::error::ErrorKind::Command(_)),
        };
        if replied {
            self.mark(KillState::Answered);
        }
        answered
            .map(|_| ())
            .map_err(|error| DriverError::Protocol(format!("the stop did not reach the server: {error}")))
    }
}

#[async_trait]
impl EngineStop for SessionKill {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Statement)
    }

    async fn stop(&self) -> Result<(), DriverError> {
        self.kill().await
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        stopped_by_kill(error)
    }
}

/// What a call holds while it runs. The client's pool lends and checks
/// its own connections, so there is no connection to give back here.
pub(crate) struct ClientCall {
    abandoned: Arc<AtomicBool>,
}

impl ClientCall {
    pub(crate) fn new() -> Self {
        Self {
            abandoned: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl CallResource for ClientCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandoned.clone()
    }

    fn discard(self) {}
}

/// How long a session whose stop went unanswered stays out of the pool:
/// longer than a stop takes to reach the server.
const QUARANTINE: Duration = Duration::from_secs(60);

/// A logical session for one call, armed for its stop.
pub(crate) async fn session(
    endpoint: &MongoEndpoint,
    client: &Client,
    stop: &SessionKill,
) -> Result<ClientSession, DriverError> {
    match client.start_session().await {
        Ok(session) => {
            stop.arm(client, &session);
            Ok(session)
        }
        Err(error) => Err(endpoint.explain(&error, LossPhase::Statement).await),
    }
}

/// Give a call's session back. A dropped session goes back to the
/// client's pool for the next call, so one whose `killSessions` is still
/// on its way is kept out of the pool until it could land, or the stop
/// would end whichever call took the session next.
pub(crate) fn release(session: ClientSession, stop: &SessionKill) {
    if stop.state() != KillState::Unanswered {
        return;
    }
    if let Ok(runtime) = tokio::runtime::Handle::try_current() {
        runtime.spawn(async move {
            tokio::time::sleep(QUARANTINE).await;
            drop(session);
        });
    }
}

/// How long the server may run what is left of a call, in the
/// milliseconds `maxTimeMS` takes.
pub(crate) fn remaining_millis(deadline: Option<Instant>) -> Option<i64> {
    deadline.map(|deadline| {
        let left = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1));
        i64::try_from(left.as_millis()).unwrap_or(i64::MAX)
    })
}

/// A generated statement as the server command it asks for, in the
/// connection's database unless it names its own.
pub(crate) fn generated(statement: &Statement, database: &str) -> Result<(ShellStatement, Plan), DriverError> {
    let parsed = parse_bound_statement(statement.sql(), statement.params().len())
        .map_err(|error| DriverError::Protocol(format!("a generated statement does not read: {error}")))?;
    let planned = plan(&parsed, database, statement.params())?;
    Ok((parsed, planned))
}
