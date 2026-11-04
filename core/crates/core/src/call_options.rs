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
}
