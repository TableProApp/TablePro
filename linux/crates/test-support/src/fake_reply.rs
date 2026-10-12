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
    /// Never answer on its own: only the call's deadline or cancel ends
    /// it, the way a statement the server never finishes behaves.
    UntilStopped,
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
            Self::UntilStopped => {
                stop.wait(None).await?;
                Err(DriverError::Protocol("an unbounded fake call finished".to_owned()))
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
        let work = async {
            match after {
                Some(after) => tokio::time::sleep(after).await,
                None => std::future::pending().await,
            }
        };
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
