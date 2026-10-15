use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

/// When a call must be done by, and how to stop it early.
///
/// Both travel together because a driver that has one without the
/// other cannot finish the job: a deadline with no cancel leaves the
/// server working after the app gave up, and a cancel with no deadline
/// hangs on a server that never answers.
#[derive(Debug, Clone)]
pub struct CallOptions {
    deadline: Option<Instant>,
    cancel: CancellationToken,
}

impl CallOptions {
    pub fn new(deadline: Option<Instant>, cancel: CancellationToken) -> Self {
        Self { deadline, cancel }
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.deadline
    }

    pub fn cancel(&self) -> &CancellationToken {
        &self.cancel
    }

    /// The same bounds on a token of the call's own: cancelling `self`
    /// still stops it, while cancelling it never reaches `self`, whose
    /// other calls share that token.
    pub fn child(&self) -> Self {
        Self {
            deadline: self.deadline,
            cancel: self.cancel.child_token(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn a_child_keeps_the_deadline_and_answers_to_its_parent() {
        let deadline = Instant::now() + Duration::from_secs(5);
        let parent = CallOptions::new(Some(deadline), CancellationToken::new());

        let child = parent.child();
        assert_eq!(child.deadline(), Some(deadline));
        parent.cancel().cancel();
        assert!(
            child.cancel().is_cancelled(),
            "cancelling the caller did not reach the call"
        );
    }

    #[test]
    fn cancelling_a_child_leaves_its_parent() {
        let parent = CallOptions::new(None, CancellationToken::new());

        parent.child().cancel().cancel();
        assert!(
            !parent.cancel().is_cancelled(),
            "a call cancelled the token its caller shares"
        );
    }
}
