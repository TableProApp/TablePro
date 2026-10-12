use std::cell::{Cell, RefCell};

use tokio_util::sync::CancellationToken;

use super::{AttemptGeneration, AttemptTicket};

/// Tracks which connect attempt is the live one.
///
/// Cancelling is cooperative and a driver blocked in a socket call
/// keeps going, so a cancelled attempt still finishes and reports.
/// `accepts` is what keeps its result from landing on top of the
/// attempt that replaced it.
#[derive(Debug, Default)]
pub struct ConnectAttempts {
    current: Cell<AttemptGeneration>,
    cancel: RefCell<Option<CancellationToken>>,
}

impl ConnectAttempts {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start an attempt, cancelling whichever one was running.
    pub fn begin(&self) -> AttemptTicket {
        self.cancel();
        let generation = self.current.get().next();
        self.current.set(generation);
        let token = CancellationToken::new();
        *self.cancel.borrow_mut() = Some(token.clone());
        AttemptTicket::new(generation, token)
    }

    pub fn cancel(&self) {
        if let Some(token) = self.cancel.borrow_mut().take() {
            token.cancel();
        }
    }

    /// Whether a result from this generation is still the one being
    /// waited on.
    pub fn accepts(&self, generation: AttemptGeneration) -> bool {
        generation == self.current.get()
    }

    pub fn current(&self) -> AttemptGeneration {
        self.current.get()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn begin_cancels_previous_token() {
        let attempts = ConnectAttempts::new();
        let first = attempts.begin();

        let second = attempts.begin();

        assert!(first.is_cancelled(), "the replaced attempt kept running");
        assert!(!second.is_cancelled());
    }

    #[test]
    fn accepts_only_latest_generation() {
        let attempts = ConnectAttempts::new();
        let first = attempts.begin();
        let second = attempts.begin();

        assert!(!attempts.accepts(first.generation()));
        assert!(attempts.accepts(second.generation()));
    }

    #[test]
    fn cancel_stops_the_live_attempt_and_leaves_nothing_to_cancel_twice() {
        let attempts = ConnectAttempts::new();
        let ticket = attempts.begin();

        attempts.cancel();
        attempts.cancel();

        assert!(ticket.is_cancelled());
        assert!(
            attempts.accepts(ticket.generation()),
            "cancelling moved the generation, so the cancelled result would be adopted"
        );
    }

    #[test]
    fn a_fresh_tracker_accepts_nothing_that_ran() {
        let attempts = ConnectAttempts::new();

        assert_eq!(attempts.current(), AttemptGeneration::FIRST);
        assert!(!attempts.accepts(AttemptGeneration::FIRST.next()));
    }
}
