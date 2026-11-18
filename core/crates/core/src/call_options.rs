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

/// Resolves when `deadline` passes, and never when there is none.
pub async fn deadline_elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_passed_deadline_resolves_and_no_deadline_never_does() {
        let past = Instant::now();
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(
            tokio::time::timeout(Duration::from_secs(1), deadline_elapsed(Some(past)))
                .await
                .is_ok()
        );
        assert!(
            tokio::time::timeout(Duration::from_secs(3600), deadline_elapsed(None))
                .await
                .is_err()
        );
    }
}
