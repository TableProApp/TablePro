use std::time::Duration;

use tablepro_core::{DriverError, TimeoutPhase};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

/// How a fake answers one call.
///
/// The variants differ in how they treat the call's deadline and
/// cancel, because that is what a conformance case tells apart: a
/// driver that honours them and one that does not.
#[derive(Debug, Clone)]
pub enum FakeReply<T> {
    /// Answer at once.
    Ready(Result<T, DriverError>),
    /// Answer after `after`, unless the call's deadline or cancel comes
    /// first, the way a conforming driver stops.
    Bounded {
        after: Duration,
        outcome: Result<T, DriverError>,
    },
    /// Answer after `after` whatever the call asked for, the way a
    /// driver that ignores its deadline and cancel behaves.
    Late {
        after: Duration,
        outcome: Result<T, DriverError>,
    },
    /// Answer once the test cancels `release`, unless the call's
    /// deadline or cancel comes first, so a case can act while the call
    /// is still running however slowly the machine runs.
    UntilReleased {
        release: CancellationToken,
        outcome: Result<T, DriverError>,
    },
    /// Never answer on its own: only the call's deadline or cancel ends
    /// it, the way a statement the server never finishes behaves.
    UntilStopped,
    /// Never answer on its own, then answer `outcome` once the call's
    /// deadline or cancel ends it, the way a driver that rolls a write
    /// back on cancel reports it.
    StoppedWith(Result<T, DriverError>),
    /// Never answer at all.
    Hang,
}

impl<T> FakeReply<T> {
    pub fn ok(value: T) -> Self {
        Self::Ready(Ok(value))
    }

    pub fn err(error: DriverError) -> Self {
        Self::Ready(Err(error))
    }

    pub(crate) async fn resolve(self, stop: &Stop<'_>) -> Result<T, DriverError> {
        match self {
            Self::Ready(outcome) => outcome,
            Self::Bounded { after, outcome } => {
                stop.wait(Some(after)).await?;
                outcome
            }
            Self::Late { after, outcome } => {
                tokio::time::sleep(after).await;
                outcome
            }
            Self::UntilReleased { release, outcome } => {
                stop.until(release.cancelled()).await?;
                outcome
            }
            Self::UntilStopped => {
                stop.wait(None).await?;
                Err(DriverError::Protocol("an unbounded fake call finished".to_owned()))
            }
            Self::StoppedWith(outcome) => {
                // Only a stop ends the wait, so its error is replaced by
                // the answer the call was scripted to give.
                let _ = stop.wait(None).await;
                outcome
            }
            Self::Hang => std::future::pending().await,
        }
    }
}

/// What can end a call early.
pub(crate) struct Stop<'a> {
    pub(crate) deadline: Option<Instant>,
    pub(crate) cancel: &'a CancellationToken,
    pub(crate) closed: &'a CancellationToken,
    pub(crate) phase: TimeoutPhase,
}

impl Stop<'_> {
    /// Wait `after`, or forever when it is `None`, giving up with the
    /// error a conforming driver reports when the call is stopped first.
    pub(crate) async fn wait(&self, after: Option<Duration>) -> Result<(), DriverError> {
        match after {
            Some(after) => self.until(tokio::time::sleep(after)).await,
            None => self.until(std::future::pending()).await,
        }
    }

    /// Wait for `work`, giving up the same way when the call is stopped
    /// first.
    pub(crate) async fn until(&self, work: impl Future<Output = ()>) -> Result<(), DriverError> {
        let deadline = async {
            match self.deadline {
                Some(deadline) => tokio::time::sleep_until(deadline).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = work => Ok(()),
            () = deadline => Err(DriverError::Timeout {
                phase: self.phase,
                server_cancelled: true,
            }),
            () = self.cancel.cancelled() => Err(DriverError::Cancelled),
            () = self.closed.cancelled() => Err(DriverError::Cancelled),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::pin::pin;

    use super::*;

    fn stop<'a>(deadline: Option<Instant>, cancel: &'a CancellationToken, closed: &'a CancellationToken) -> Stop<'a> {
        Stop {
            deadline,
            cancel,
            closed,
            phase: TimeoutPhase::Statement,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn an_until_released_reply_answers_only_once_released() {
        let (release, cancel, closed) = (
            CancellationToken::new(),
            CancellationToken::new(),
            CancellationToken::new(),
        );
        let stop = stop(None, &cancel, &closed);
        let reply = FakeReply::UntilReleased {
            release: release.clone(),
            outcome: Ok(7),
        };
        let mut answering = pin!(reply.resolve(&stop));

        let early = tokio::time::timeout(Duration::from_secs(3600), &mut answering).await;
        assert!(early.is_err(), "answered before the release: {early:?}");
        release.cancel();

        assert_eq!(answering.await, Ok(7));
    }

    #[tokio::test(start_paused = true)]
    async fn an_until_released_reply_gives_way_to_the_deadline_and_the_cancel() {
        let (release, cancel, closed) = (
            CancellationToken::new(),
            CancellationToken::new(),
            CancellationToken::new(),
        );
        let reply = || FakeReply::UntilReleased {
            release: release.clone(),
            outcome: Ok(7),
        };

        let timed = reply()
            .resolve(&stop(Some(Instant::now() + Duration::from_secs(1)), &cancel, &closed))
            .await;
        cancel.cancel();
        let cancelled = reply().resolve(&stop(None, &cancel, &closed)).await;

        assert_eq!(
            timed,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            })
        );
        assert_eq!(cancelled, Err(DriverError::Cancelled));
    }
}
