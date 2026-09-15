use std::sync::{Arc, OnceLock};

use tokio_util::sync::CancellationToken;

/// Why a call is being stopped.
///
/// The reason decides what the caller is told afterwards: the same
/// half-finished statement reads as cancelled, as a timeout, or as the
/// app closing, and only one of those is worth a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StopReason {
    Cancelled,
    DeadlineElapsed,
    Shutdown,
}

/// The stop as the work itself sees it.
///
/// A client that borrows its connection for the whole request cannot be
/// interrupted from outside, so the work carries this and checks it
/// between statements, or selects on it where the protocol allows a
/// stop mid-flight.
#[derive(Debug, Clone)]
pub struct StopRequest {
    token: CancellationToken,
    reason: Arc<OnceLock<StopReason>>,
}

impl StopRequest {
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            reason: Arc::new(OnceLock::new()),
        }
    }

    /// Ask the work to stop. The first reason is the one that sticks,
    /// because it is the one that actually interrupted the call.
    pub fn request(&self, reason: StopReason) {
        let _ = self.reason.set(reason);
        self.token.cancel();
    }

    pub fn reason(&self) -> Option<StopReason> {
        self.reason.get().copied()
    }

    pub fn is_requested(&self) -> bool {
        self.token.is_cancelled()
    }

    /// Resolves once a stop has been asked for.
    pub async fn requested(&self) {
        self.token.cancelled().await;
    }
}

impl Default for StopRequest {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_first_reason_is_the_one_that_sticks() {
        let request = StopRequest::new();

        request.request(StopReason::DeadlineElapsed);
        request.request(StopReason::Shutdown);

        assert_eq!(request.reason(), Some(StopReason::DeadlineElapsed));
    }

    #[tokio::test]
    async fn a_clone_sees_the_same_stop() {
        let request = StopRequest::new();
        let copy = request.clone();

        request.request(StopReason::Cancelled);

        assert!(copy.is_requested());
        copy.requested().await;
        assert_eq!(copy.reason(), Some(StopReason::Cancelled));
    }

    #[test]
    fn a_fresh_request_has_no_reason() {
        let request = StopRequest::new();

        assert!(!request.is_requested());
        assert_eq!(request.reason(), None);
    }
}
