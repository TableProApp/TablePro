use std::future::Future;
use std::sync::Arc;

use redis::aio::MultiplexedConnection;
use redis::{Cmd, Pipeline, Value};
use tablepro_core::{DriverError, LossPhase, StopReason, StopRequest, TimeoutPhase};
use tokio::task::JoinHandle;

use crate::errors::{map_error, server_error};

/// One connection to the server: redis-rs's multiplexed handle, the task
/// that reads its socket, and the id the server knows it by.
///
/// Clones share the connection. The reading task stops with the last
/// clone, which closes the socket.
#[derive(Clone)]
pub(crate) struct Link {
    connection: MultiplexedConnection,
    client_id: Option<u64>,
    _reader: Arc<Reader>,
}

struct Reader(JoinHandle<()>);

impl Drop for Reader {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl Link {
    pub(crate) fn new(connection: MultiplexedConnection, reader: JoinHandle<()>) -> Self {
        Self {
            connection,
            client_id: None,
            _reader: Arc::new(Reader(reader)),
        }
    }

    pub(crate) fn with_client_id(mut self, client_id: Option<u64>) -> Self {
        self.client_id = client_id;
        self
    }

    /// What `CLIENT ID` said, which a stop names. `None` when the login
    /// may not ask.
    pub(crate) fn client_id(&self) -> Option<u64> {
        self.client_id
    }

    /// Whether the socket is gone: the reading task ended.
    pub(crate) fn is_closed(&self) -> bool {
        self._reader.0.is_finished()
    }

    /// Send one command and read its reply, an error reply included as
    /// `Value::ServerError`.
    pub(crate) async fn send(&self, command: &Cmd) -> Result<Value, DriverError> {
        let mut connection = self.connection.clone();
        connection
            .send_packed_command(command)
            .await
            .map_err(|error| map_error(&error, LossPhase::Statement))
    }

    /// Send one command and require a reply that is not an error.
    pub(crate) async fn ask(&self, command: &Cmd) -> Result<Value, DriverError> {
        match self.send(command).await? {
            Value::ServerError(error) => Err(server_error(&error)),
            reply => Ok(reply),
        }
    }

    /// Send every command of `pipeline` in one round trip, a reply each.
    pub(crate) async fn send_all(&self, pipeline: &Pipeline) -> Result<Vec<Value>, DriverError> {
        let mut connection = self.connection.clone();
        connection
            .send_packed_commands(pipeline, 0, pipeline.len())
            .await
            .map_err(|error| map_error(&error, LossPhase::Statement))
    }
}

/// A command from its arguments, the name first.
pub(crate) fn command<A: AsRef<[u8]>>(arguments: &[A]) -> Cmd {
    let mut command = Cmd::new();
    for argument in arguments {
        command.arg(argument.as_ref());
    }
    command
}

/// `work`, or the stop as its error once one is asked for. A reply still
/// on its way when the stop wins is read and dropped by redis-rs, so the
/// link stays in step.
pub(crate) async fn stoppable<T>(
    stop: &StopRequest,
    work: impl Future<Output = Result<T, DriverError>>,
) -> Result<T, DriverError> {
    tokio::select! {
        biased;
        () = stop.requested() => Err(stopped(stop)),
        outcome = work => outcome,
    }
}

/// What a call stopped between commands reports. Nothing reached the
/// server, so a deadline is a timeout the server did not cancel.
pub(crate) fn stopped(stop: &StopRequest) -> DriverError {
    match stop.reason() {
        Some(StopReason::DeadlineElapsed) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        Some(StopReason::Cancelled | StopReason::Shutdown) | None => DriverError::Cancelled,
    }
}
