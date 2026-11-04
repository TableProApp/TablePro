use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{DriverError, LossPhase, ResultSink, RunOptions, RunSummary, UserSql};
use tokio::sync::{mpsc, oneshot};
use tokio_postgres::error::DbError;
use tokio_util::sync::CancellationToken;

use super::session_core::{SessionCore, drive};
use super::session_status::SessionStatus;
use crate::physical::PgRawConnection;

pub(crate) enum Command {
    Run {
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
        reply: oneshot::Sender<Result<RunSummary, DriverError>>,
    },
    Close,
}

/// The session's task. It owns the client and the connection's I/O
/// half and polls both itself, so notices and parameter changes stay
/// with the session. A result stream's channel is bounded, so while a
/// run awaits the sink the connection stops reading the socket, which
/// holds a fast server back for a slow grid.
pub(crate) async fn session_actor(
    mut core: SessionCore,
    connection: PgRawConnection,
    notices: mpsc::UnboundedSender<DbError>,
    mut commands: mpsc::Receiver<Command>,
    status: Arc<SessionStatus>,
    shutdown: CancellationToken,
    close_timeout: Duration,
) {
    let driving = drive(connection, notices, core.conforming.clone());
    let mut driving = std::pin::pin!(driving);
    loop {
        let command = tokio::select! {
            () = &mut driving => break,
            command = commands.recv() => command,
        };
        let Some(Command::Run {
            sql,
            options,
            mut sink,
            reply,
        }) = command
        else {
            // A close, or every handle is gone. Dropping the client first
            // lets the connection send Terminate before it ends.
            drop(core);
            let _ = tokio::time::timeout(close_timeout, &mut driving).await;
            status.lose();
            return;
        };
        let outcome = tokio::select! {
            () = &mut driving => None,
            outcome = core.run(&sql, options, sink.as_mut(), &shutdown) => outcome.ok(),
        };
        match outcome {
            Some(summary) => {
                status.finish(summary.transaction_state);
                let _ = reply.send(Ok(summary));
            }
            None => {
                status.lose();
                let _ = reply.send(Err(DriverError::ConnectionLost {
                    during: LossPhase::Statement,
                }));
                break;
            }
        }
    }
    status.lose();
}
