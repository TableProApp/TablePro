//! Stopping a request from the task that owns the client.
//!
//! tiberius borrows its client for the whole of a request, so a stop
//! first has to end that borrow, then send the attention on the same
//! client and read the response up to its acknowledgement. Ending the
//! borrow at the wrong moment leaves half a token unread, and then the
//! acknowledgement cannot be found, so each stop first tries to reach a
//! point between tokens and records whether it did.

use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use futures_util::TryStreamExt;
use tablepro_core::{DriverError, StopRequest};
use tiberius::{QueryItem, QueryStream};
use tokio::time::Instant;
use tracing::debug;

use crate::cancel::{MssqlStop, StopProgress, unconfirmed_stop};
use crate::errors::{ends_connection, map_error};
use crate::physical::MssqlClient;
use crate::transport_io::ReadTally;

const ROLL_BACK_OPEN: &str = "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION";

/// Where a stopped request left the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Halt {
    /// The stop came before anything was sent.
    Unsent,
    /// The response ended on its own, so nothing is left to stop.
    Finished,
    /// The decoder stands between tokens, so the attention's
    /// acknowledgement can be read back cleanly.
    Boundary,
    /// A token may be half read, and what follows it is out of step.
    MidToken,
}

/// Why a request did not produce its result.
#[derive(Debug)]
pub(crate) enum Interrupt {
    Stopped(Halt),
    Failed(DriverError),
}

impl From<DriverError> for Interrupt {
    fn from(error: DriverError) -> Self {
        Self::Failed(error)
    }
}

/// How a stopped request spends the cancel grace: first reaching a
/// point between tokens, then waiting for the attention's answer. Both
/// fit inside the grace with room left for the call to return.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StopPolicy {
    pub(crate) window: Duration,
    pub(crate) budget: Duration,
}

impl StopPolicy {
    pub(crate) fn within(grace: Duration) -> Self {
        Self {
            window: grace / 4,
            budget: grace / 2,
        }
    }
}

/// How the server answered an attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Answer {
    Acknowledged,
    /// Something came back that was not the acknowledgement: the route
    /// is alive, the connection is not usable.
    Garbled,
    /// Nothing came back in time, or the socket failed.
    Unanswered,
}

/// One request's view of its stop.
#[derive(Debug)]
pub(crate) struct Watch {
    request: StopRequest,
    tally: ReadTally,
    policy: StopPolicy,
    sent_at: AtomicU64,
    spoiled: AtomicBool,
}

impl Watch {
    pub(crate) fn new(request: StopRequest, tally: ReadTally, policy: StopPolicy) -> Self {
        Self {
            sent_at: AtomicU64::new(tally.bytes()),
            request,
            tally,
            policy,
            spoiled: AtomicBool::new(false),
        }
    }

    pub(crate) fn request(&self) -> &StopRequest {
        &self.request
    }

    pub(crate) fn policy(&self) -> StopPolicy {
        self.policy
    }

    /// The connection ended up somewhere it must not be reused from.
    pub(crate) fn spoil(&self) {
        self.spoiled.store(true, Ordering::SeqCst);
    }

    pub(crate) fn spoiled(&self) -> bool {
        self.spoiled.load(Ordering::SeqCst)
    }

    /// Send a request whose response is read afterwards, and wait for its
    /// first answer unless a stop comes first.
    pub(crate) async fn start<T, F>(&self, sending: F) -> Result<T, Interrupt>
    where
        F: Future<Output = Result<T, tiberius::error::Error>>,
    {
        self.race(sending, Halt::Boundary).await
    }

    /// Run a request whose future reads its whole response.
    pub(crate) async fn finish<T, F>(&self, running: F) -> Result<T, Interrupt>
    where
        F: Future<Output = Result<T, tiberius::error::Error>>,
    {
        self.race(running, Halt::Finished).await
    }

    async fn race<T, F>(&self, request: F, once_done: Halt) -> Result<T, Interrupt>
    where
        F: Future<Output = Result<T, tiberius::error::Error>>,
    {
        // Checked first: the race below polls the request before the
        // stop, and a stop that is already due must not start a write it
        // would then cut in half.
        if self.request.is_requested() {
            return Err(Interrupt::Stopped(Halt::Unsent));
        }
        self.sent_at.store(self.tally.bytes(), Ordering::SeqCst);
        let mut request = std::pin::pin!(request);
        tokio::select! {
            biased;
            done = &mut request => return done.map_err(|error| Interrupt::Failed(map_error(error))),
            () = self.request.requested() => {}
        }
        // A request half written or half read finishes cleanly if it is
        // only given a moment, which is worth more than stopping at once.
        let halt = match tokio::time::timeout(self.policy.window, &mut request).await {
            Ok(Ok(_)) => once_done,
            Ok(Err(error)) => return Err(ended_by(error)),
            Err(_) => self.halt_while_waiting(),
        };
        Err(Interrupt::Stopped(halt))
    }

    /// The next item of a response, unless a stop comes first.
    pub(crate) async fn next(&self, stream: &mut QueryStream<'_>) -> Result<Option<QueryItem>, Interrupt> {
        if self.request.is_requested() {
            return Err(Interrupt::Stopped(Halt::Boundary));
        }
        tokio::select! {
            biased;
            item = stream.try_next() => return item.map_err(|error| Interrupt::Failed(map_error(error))),
            () = self.request.requested() => {}
        }
        // The token being decoded lives in the stream, not in the future
        // the race dropped, so asking again resumes it.
        let halt = match tokio::time::timeout(self.policy.window, stream.try_next()).await {
            Ok(Ok(Some(_))) => Halt::Boundary,
            Ok(Ok(None)) => Halt::Finished,
            Ok(Err(error)) => return Err(ended_by(error)),
            Err(_) => self.halt_while_waiting(),
        };
        Err(Interrupt::Stopped(halt))
    }

    /// A request still waiting has consumed nothing if nothing arrived,
    /// and may be inside a token if anything did.
    fn halt_while_waiting(&self) -> Halt {
        match self.tally.bytes() == self.sent_at.load(Ordering::SeqCst) {
            true => Halt::Boundary,
            false => Halt::MidToken,
        }
    }
}

/// A request that ended with an error while it was being stopped: the
/// server's own error ends the response, a broken socket ends the
/// connection.
fn ended_by(error: tiberius::error::Error) -> Interrupt {
    let mapped = map_error(error);
    match ends_connection(&mapped) {
        true => Interrupt::Failed(mapped),
        false => Interrupt::Stopped(Halt::Finished),
    }
}

/// What became of a request, and whether its connection can run another.
#[derive(Debug)]
pub(crate) struct Concluded<T> {
    pub(crate) result: Result<T, DriverError>,
    pub(crate) reusable: bool,
}

/// Finish a request whatever ended it. A stopped one has its attention
/// sent and answered, and with `roll_back` the connection is left with
/// no transaction open, because an attention does not end one.
pub(crate) async fn conclude<T>(
    client: &mut MssqlClient,
    watch: &Watch,
    outcome: Result<T, Interrupt>,
    stop: &MssqlStop,
    roll_back: bool,
) -> Concluded<T> {
    let (result, reusable) = match outcome {
        Ok(value) => (Ok(value), true),
        Err(Interrupt::Failed(error)) => {
            let reusable = !ends_connection(&error);
            (Err(error), reusable)
        }
        Err(Interrupt::Stopped(halt)) => {
            let (error, reusable) = stopped(client, watch, halt, stop, roll_back).await;
            (Err(error), reusable)
        }
    };
    Concluded {
        result,
        reusable: reusable && !watch.spoiled(),
    }
}

async fn stopped(
    client: &mut MssqlClient,
    watch: &Watch,
    halt: Halt,
    stop: &MssqlStop,
    roll_back: bool,
) -> (DriverError, bool) {
    let until = Instant::now() + watch.policy().budget;
    match halt {
        Halt::Unsent | Halt::Finished => {
            let clean = !roll_back || roll_back_open(client, until).await;
            (DriverError::Cancelled, clean)
        }
        Halt::Boundary | Halt::MidToken => {
            let answer = attention(client, until).await;
            stop.record(match answer {
                Answer::Unanswered => StopProgress::Failed,
                Answer::Acknowledged | Answer::Garbled => StopProgress::Delivered,
            });
            match answer {
                Answer::Acknowledged => {
                    let clean = halt == Halt::Boundary && (!roll_back || roll_back_open(client, until).await);
                    (DriverError::Cancelled, clean)
                }
                Answer::Garbled | Answer::Unanswered => (unconfirmed_stop(watch.request()), false),
            }
        }
    }
}

/// Send the attention and read up to its acknowledgement, by `until`.
pub(crate) async fn attention(client: &mut MssqlClient, until: Instant) -> Answer {
    match tokio::time::timeout_at(until, client.cancel_query()).await {
        Ok(Ok(())) => Answer::Acknowledged,
        Ok(Err(error)) => {
            debug!(%error, "the attention was not acknowledged");
            match error {
                tiberius::error::Error::Io { .. } => Answer::Unanswered,
                _ => Answer::Garbled,
            }
        }
        Err(_) => Answer::Unanswered,
    }
}

/// Roll back whatever transaction the connection holds, by `until`.
pub(crate) async fn roll_back_open(client: &mut MssqlClient, until: Instant) -> bool {
    let rolling_back = async {
        let stream = client.simple_query(ROLL_BACK_OPEN).await?;
        stream.into_results().await.map(|_| ())
    };
    matches!(tokio::time::timeout_at(until, rolling_back).await, Ok(Ok(())))
}

/// Stop a response the caller has read enough of. Reading the rest
/// could mean millions of rows nobody wants, so the server is told to
/// stop instead; a connection that does not answer is not reused.
pub(crate) async fn cut_short(client: &mut MssqlClient, watch: &Watch, roll_back: bool) {
    let until = Instant::now() + watch.policy().budget;
    let clean =
        attention(client, until).await == Answer::Acknowledged && (!roll_back || roll_back_open(client, until).await);
    if !clean {
        watch.spoil();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::StopReason;

    use super::*;

    fn watch(tally: &ReadTally) -> Watch {
        Watch::new(
            StopRequest::new(),
            tally.clone(),
            StopPolicy::within(Duration::from_secs(1)),
        )
    }

    #[test]
    fn the_policy_leaves_part_of_the_grace_for_returning() {
        let policy = StopPolicy::within(Duration::from_secs(4));

        assert_eq!(policy.window, Duration::from_secs(1));
        assert_eq!(policy.budget, Duration::from_secs(2));
        assert!(policy.window + policy.budget < Duration::from_secs(4));
    }

    #[tokio::test]
    async fn a_stop_already_due_sends_nothing() {
        let watch = watch(&ReadTally::new());
        watch.request().request(StopReason::Cancelled);
        let mut sent = false;

        let outcome = watch
            .start(async {
                sent = true;
                Ok::<_, tiberius::error::Error>(())
            })
            .await;

        assert!(matches!(outcome, Err(Interrupt::Stopped(Halt::Unsent))));
        assert!(!sent);
    }

    #[tokio::test(start_paused = true)]
    async fn a_request_with_no_answer_yet_stops_at_a_boundary() {
        let watch = watch(&ReadTally::new());
        let request = watch.request().clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            request.request(StopReason::DeadlineElapsed);
        });

        let outcome = watch
            .start(std::future::pending::<Result<(), tiberius::error::Error>>())
            .await;

        assert!(matches!(outcome, Err(Interrupt::Stopped(Halt::Boundary))));
    }

    #[tokio::test]
    async fn a_request_that_ends_while_stopping_finished_on_its_own() {
        let watch = watch(&ReadTally::new());
        let request = watch.request().clone();

        let outcome = watch
            .finish(async move {
                request.request(StopReason::Cancelled);
                tokio::task::yield_now().await;
                Ok::<_, tiberius::error::Error>(7)
            })
            .await;

        assert!(matches!(outcome, Err(Interrupt::Stopped(Halt::Finished))));
    }

    #[tokio::test]
    async fn a_broken_or_garbled_response_while_stopping_ends_the_connection() {
        let garbled = tiberius::error::Error::Conversion("nothing to see".into());
        let broken = tiberius::error::Error::Io {
            kind: tiberius::error::IoErrorKind::BrokenPipe,
            message: "broken pipe".to_owned(),
        };

        assert!(matches!(
            ended_by(broken),
            Interrupt::Failed(DriverError::ConnectionLost { .. })
        ));
        assert!(matches!(ended_by(garbled), Interrupt::Failed(DriverError::Protocol(_))));
    }
}
