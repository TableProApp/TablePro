use std::sync::Arc;
use std::time::Duration;

use tablepro_core::DriverError;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_postgres::CancelToken;
use tokio_util::sync::CancellationToken;

use crate::physical::PgEndpoint;

/// Why a run stopped before its script did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Interrupt {
    Cancelled,
    DeadlineElapsed,
    /// The sink said nobody is reading any more.
    ConsumerGone,
}

/// The run's stop: what triggers it, and the cancel request it sent.
///
/// The cancel request runs as a task of its own, so it reaches the
/// server while the run keeps reading what the statement still sends.
/// Nothing new goes out until the request has settled, because a cancel
/// request names the backend, not the statement, and a late one would
/// cancel whatever the run sent next.
pub(crate) struct StopWatch {
    cancel: CancellationToken,
    shutdown: CancellationToken,
    run_deadline: Option<Instant>,
    statement_deadline: Option<Instant>,
    grace: Duration,
    fired: Option<Interrupt>,
    give_up: Option<Instant>,
    request: Option<JoinHandle<Result<(), DriverError>>>,
}

impl StopWatch {
    pub(crate) fn new(
        cancel: CancellationToken,
        shutdown: CancellationToken,
        run_deadline: Option<Instant>,
        grace: Duration,
    ) -> Self {
        Self {
            cancel,
            shutdown,
            run_deadline,
            statement_deadline: run_deadline,
            grace,
            fired: None,
            give_up: None,
            request: None,
        }
    }

    /// Bound the next statement by the session's statement timeout as
    /// well as the run's deadline.
    pub(crate) fn begin_statement(&mut self, statement_timeout: Option<Duration>) {
        let own = statement_timeout.map(|timeout| Instant::now() + timeout);
        self.statement_deadline = match (self.run_deadline, own) {
            (Some(run), Some(own)) => Some(run.min(own)),
            (run, own) => run.or(own),
        };
    }

    pub(crate) fn fired(&self) -> Option<Interrupt> {
        self.fired
    }

    /// Resolves when the run should stop.
    pub(crate) async fn triggered(&self) -> Interrupt {
        let deadline = async {
            match self.statement_deadline {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = self.cancel.cancelled() => Interrupt::Cancelled,
            () = self.shutdown.cancelled() => Interrupt::Cancelled,
            () = deadline => Interrupt::DeadlineElapsed,
        }
    }

    /// A trigger that came due while nothing was running.
    pub(crate) fn due(&self) -> Option<Interrupt> {
        if self.cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Some(Interrupt::Cancelled);
        }
        self.statement_deadline
            .filter(|at| Instant::now() >= *at)
            .map(|_| Interrupt::DeadlineElapsed)
    }

    /// Record the stop and, where a statement is running, send the
    /// cancel request for it.
    pub(crate) fn fire(&mut self, interrupt: Interrupt, running: Option<(Arc<PgEndpoint>, CancelToken)>) {
        if self.fired.is_some() {
            return;
        }
        self.fired = Some(interrupt);
        self.give_up = Some(Instant::now() + self.grace);
        if let Some((endpoint, token)) = running {
            self.request = Some(tokio::spawn(async move { endpoint.cancel_request(&token).await }));
        }
    }

    /// Resolves once the grace after the stop has run out: a statement
    /// still running then never answered its cancel.
    pub(crate) async fn gave_up(&self) {
        match self.give_up {
            Some(at) => tokio::time::sleep_until(at).await,
            None => std::future::pending().await,
        }
    }

    /// Wait for an outstanding cancel request before anything else goes
    /// to the server. One that has not settled by the end of the grace is
    /// dropped: it could not reach the server, so it cannot land late.
    pub(crate) async fn settle(&mut self) {
        let Some(mut request) = self.request.take() else {
            return;
        };
        let give_up = self.give_up.unwrap_or_else(Instant::now);
        if tokio::time::timeout_at(give_up, &mut request).await.is_err() {
            request.abort();
        }
    }
}
