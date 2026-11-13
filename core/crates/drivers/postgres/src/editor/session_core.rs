use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::Poll;
use std::time::Duration;

use tablepro_core::{CopyInRows, CopyInSummary, ResultSink, RunOptions, RunSummary, ServerCode, ServerNotice, UserSql};
use tokio::time::Instant;
use tokio_postgres::error::DbError;
use tokio_postgres::{AsyncMessage, CancelToken, Client};
use tokio_util::sync::CancellationToken;

use super::copy_flight::NoRows;
use super::notice_queue::{NoticeQueue, NoticeSender};
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
    notices: NoticeQueue<ServerNotice>,
    statement_timeout: Option<Duration>,
    grace: Duration,
}

impl SessionCore {
    pub(crate) fn new(
        client: Client,
        endpoint: Arc<PgEndpoint>,
        read_only: bool,
        statement_timeout: Option<Duration>,
        notices: NoticeQueue<ServerNotice>,
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

    pub(crate) fn next_notice(&mut self) -> Option<ServerNotice> {
        self.notices.next()
    }

    pub(crate) fn discard_notices(&mut self) {
        self.notices.discard();
    }

    pub(crate) fn notices_dropped(&self) -> bool {
        self.notices.dropped()
    }

    pub(crate) async fn run(
        &mut self,
        sql: &UserSql,
        options: RunOptions,
        sink: &mut dyn ResultSink,
        shutdown: &CancellationToken,
    ) -> Result<RunSummary, Lost> {
        let started = Instant::now();
        self.notices.start_run();
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

    /// Run a `COPY ... FROM STDIN` with `rows` as its data.
    pub(crate) async fn copy_in(
        &mut self,
        statement: &UserSql,
        mut rows: CopyInRows,
        options: RunOptions,
        shutdown: &CancellationToken,
    ) -> Result<CopyInSummary, Lost> {
        self.notices.start_run();
        let deadline = options.deadline.map(|deadline| Instant::now() + deadline);
        let watch = StopWatch::new(options.cancel, shutdown.clone(), deadline, self.grace);
        let mut sink = NoRows;
        let mut run = Run::new(self, &mut sink, watch, options.row_limit);
        let copied = run.copy_in(statement.as_str(), &mut rows).await?;
        if run.stopped() {
            run.probe().await?;
        }
        self.notices.discard();
        Ok(CopyInSummary {
            end: copied.end,
            rows: copied.rows,
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
    notices: NoticeSender<ServerNotice>,
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
                Poll::Ready(Some(Ok(AsyncMessage::Notice(notice)))) => notices.send(kept_notice(&notice)),
                Poll::Ready(Some(Ok(_))) => {}
                Poll::Ready(Some(Err(_)) | None) => return Poll::Ready(()),
            }
        }
    })
    .await;
}

/// The longest notice message a run keeps, in bytes: a run holds up to
/// `NOTICES_PER_RUN` of them until it reads them.
const NOTICE_MESSAGE_BYTES: usize = 32_767;

fn kept_notice(notice: &DbError) -> ServerNotice {
    ServerNotice {
        severity: notice.severity().to_owned(),
        message: clipped(notice.message()),
        code: Some(ServerCode::SqlState(notice.code().code().to_owned())),
    }
}

fn clipped(message: &str) -> String {
    if message.len() <= NOTICE_MESSAGE_BYTES {
        return message.to_owned();
    }
    let mut end = NOTICE_MESSAGE_BYTES;
    while !message.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\u{2026}", &message[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_within_the_limit_is_kept_whole() {
        let message = "x".repeat(NOTICE_MESSAGE_BYTES);
        assert_eq!(clipped(&message), message);
    }

    #[test]
    fn a_longer_message_is_cut_on_a_character_boundary() {
        let message = format!("{}\u{e9}tail", "x".repeat(NOTICE_MESSAGE_BYTES - 1));
        let kept = clipped(&message);
        assert_eq!(kept, format!("{}\u{2026}", "x".repeat(NOTICE_MESSAGE_BYTES - 1)));
    }
}
