use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::Poll;
use std::time::Duration;

use tablepro_core::{ResultSink, RunOptions, RunSummary, UserSql};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::time::Instant;
use tokio_postgres::error::DbError;
use tokio_postgres::{AsyncMessage, CancelToken, Client};
use tokio_util::sync::CancellationToken;

use super::run::Run;
use super::stop_watch::StopWatch;
use super::transaction_tracker::TransactionTracker;
use crate::physical::{PgEndpoint, PgRawConnection};

/// The session's connection is gone, or no longer answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Lost;

/// What the session actor owns besides the connection's I/O half.
pub(crate) struct SessionCore {
    pub(crate) client: Client,
    pub(crate) endpoint: Arc<PgEndpoint>,
    pub(crate) cancel_token: CancelToken,
    pub(crate) tracker: TransactionTracker,
    pub(crate) read_only: bool,
    pub(crate) conforming: Arc<AtomicBool>,
    notices: UnboundedReceiver<DbError>,
    statement_timeout: Option<Duration>,
    grace: Duration,
}

impl SessionCore {
    pub(crate) fn new(
        client: Client,
        endpoint: Arc<PgEndpoint>,
        read_only: bool,
        statement_timeout: Option<Duration>,
        notices: UnboundedReceiver<DbError>,
        conforming: Arc<AtomicBool>,
    ) -> Self {
        let cancel_token = client.cancel_token();
        let grace = endpoint.liveness().cancel_grace;
        Self {
            client,
            endpoint,
            cancel_token,
            tracker: TransactionTracker::default(),
            read_only,
            conforming,
            notices,
            statement_timeout,
            grace,
        }
    }

    pub(crate) fn statement_timeout(&self) -> Option<Duration> {
        self.statement_timeout
    }

    pub(crate) fn next_notice(&mut self) -> Option<DbError> {
        self.notices.try_recv().ok()
    }

    pub(crate) fn discard_notices(&mut self) {
        while self.notices.try_recv().is_ok() {}
    }

    pub(crate) async fn run(
        &mut self,
        sql: &UserSql,
        options: RunOptions,
        sink: &mut dyn ResultSink,
        shutdown: &CancellationToken,
    ) -> Result<RunSummary, Lost> {
        let started = Instant::now();
        let deadline = options.deadline.map(|deadline| started + deadline);
        let watch = StopWatch::new(options.cancel, shutdown.clone(), deadline, self.grace);
        let mut run = Run::new(self, sink, watch, options.row_limit);
        let end = run.script(sql.as_str()).await?;
        // A cancel request may have landed on one of the driver's own
        // statements, so after a stop the status is asked, not assumed.
        if run.stopped() {
            run.probe().await?;
        }
        run.forward_notices().await;
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end,
            transaction_state: self.tracker.state().into(),
        })
    }
}

/// Drive the connection's I/O, which the actor polls itself so notices
/// and parameter changes stay with the session: notices go to the run,
/// and `standard_conforming_strings` decides how the next statement is
/// split. Resolves when the connection ends.
pub(crate) async fn drive(
    mut connection: PgRawConnection,
    notices: UnboundedSender<DbError>,
    conforming: Arc<AtomicBool>,
) {
    std::future::poll_fn(|cx| {
        loop {
            let polled = connection.poll_message(cx);
            conforming.store(
                connection.parameter("standard_conforming_strings") != Some("off"),
                Ordering::SeqCst,
            );
            match polled {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Some(Ok(AsyncMessage::Notice(notice)))) => {
                    let _ = notices.send(notice);
                }
                Poll::Ready(Some(Ok(_))) => {}
                Poll::Ready(Some(Err(_)) | None) => return Poll::Ready(()),
            }
        }
    })
    .await;
}
