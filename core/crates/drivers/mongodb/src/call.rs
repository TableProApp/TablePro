use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bson::{Bson, Document, doc};
use mongodb::{Client, ClientSession, Database};
use tablepro_core::sql_syntax::mongo::{ShellStatement, parse_bound_statement};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallResource, DriverError, EngineStop, LossPhase, StopDelivery, StopReason, StopRequest, StopScope, TimeoutPhase,
};
use tokio::time::Instant;

use crate::endpoint::MongoEndpoint;
use crate::errors::stopped_by_kill;
use crate::shell_command::{Plan, plan};

/// The stop of one call: `killSessions` for the logical session the call
/// runs in, which ends the operation that session has on the server and
/// closes its cursors. A server that refuses it, as Atlas M0 and Flex do,
/// gets `killOp` for each of the login's own operations in that session
/// instead. Every call has a session of its own, so the stop names the
/// call and nothing else.
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
        let admin = client.database("admin");
        let answered = match admin.run_command(doc! { "killSessions": [session.clone()] }).await {
            Ok(_) => Ok(()),
            Err(refused) if refused_by_server(&refused) => {
                tracing::debug!(error = %refused, "killSessions refused, stopping the session's operations by id");
                kill_operations(&admin, &session).await
            }
            Err(error) => Err(error),
        };
        // Any reply, a refusal included, came back over the route. Until
        // the last command of the stop is answered, one could still land.
        let replied = match &answered {
            Ok(()) => true,
            Err(error) => refused_by_server(error),
        };
        if replied {
            self.mark(KillState::Answered);
        }
        answered.map_err(|error| DriverError::Protocol(format!("the stop did not reach the server: {error}")))
    }
}

fn refused_by_server(error: &mongodb::error::Error) -> bool {
    matches!(error.kind.as_ref(), mongodb::error::ErrorKind::Command(_))
}

/// `killOp` for each operation the login runs in `session`. Any user may
/// list and kill their own operations, and the session's id names only
/// this call's.
async fn kill_operations(admin: &Database, session: &Document) -> Result<(), mongodb::error::Error> {
    let Some(id) = session.get("id") else {
        return Ok(());
    };
    // The command, not the `$currentOp` stage: Atlas documents it on every tier.
    let listed = admin
        .run_command(doc! { "currentOp": 1_i32, "$ownOps": true, "lsid.id": id.clone() })
        .await?;
    let operations = listed.get_array("inprog").map(Vec::as_slice).unwrap_or_default();
    for opid in operations.iter().filter_map(|operation| in_session(operation, id)) {
        admin.run_command(doc! { "killOp": 1_i32, "op": opid.clone() }).await?;
    }
    Ok(())
}

/// The `opid` of a `currentOp` entry that runs in the session `id`
/// names. A server that ignores the filter lists the login's other
/// operations too, and those are not this call's to end.
fn in_session<'a>(operation: &'a Bson, id: &Bson) -> Option<&'a Bson> {
    let operation = operation.as_document()?;
    match operation.get_document("lsid").ok()?.get("id") {
        Some(session) if session == id => operation.get("opid"),
        _ => None,
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

/// A call that ends at its own stop, before it asks the server for more,
/// reads as what stopped it. The server was not told, so a deadline is
/// never a statement the server cancelled.
pub(crate) fn stopped(request: &StopRequest) -> DriverError {
    match request.reason() {
        Some(StopReason::DeadlineElapsed) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        Some(StopReason::Shutdown) => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        Some(StopReason::Cancelled) | None => DriverError::Cancelled,
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

#[cfg(test)]
mod tests {
    use bson::Binary;
    use bson::spec::BinarySubtype;

    use super::*;

    #[test]
    fn a_read_that_ends_at_its_stop_reads_as_what_stopped_it() {
        let stop = |reason: Option<StopReason>| {
            let request = StopRequest::new();
            if let Some(reason) = reason {
                request.request(reason);
            }
            stopped(&request)
        };

        assert_eq!(
            stop(Some(StopReason::DeadlineElapsed)),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            }
        );
        assert_eq!(
            stop(Some(StopReason::Shutdown)),
            DriverError::ConnectionLost {
                during: LossPhase::Statement
            }
        );
        assert_eq!(stop(Some(StopReason::Cancelled)), DriverError::Cancelled);
        assert_eq!(stop(None), DriverError::Cancelled);
    }

    #[test]
    fn only_an_operation_of_the_session_is_ended() {
        let id = |byte: u8| {
            Bson::Binary(Binary {
                subtype: BinarySubtype::Uuid,
                bytes: vec![byte; 16],
            })
        };
        let entry = |session: Option<Bson>, opid: i32| {
            let mut operation = doc! { "opid": opid, "op": "getmore" };
            if let Some(session) = session {
                operation.insert("lsid", doc! { "id": session });
            }
            Bson::Document(operation)
        };

        assert_eq!(in_session(&entry(Some(id(1)), 7), &id(1)), Some(&Bson::Int32(7)));
        assert_eq!(in_session(&entry(Some(id(2)), 8), &id(1)), None, "another session's");
        assert_eq!(in_session(&entry(None, 9), &id(1)), None, "no session's");
    }
}
