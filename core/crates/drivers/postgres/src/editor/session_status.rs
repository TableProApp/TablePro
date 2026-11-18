use std::sync::Mutex;

use tablepro_core::{DriverError, EditorSessionState, EditorSessionStatus, TransactionState};

/// What the session handle can answer without asking the actor, which
/// may be busy running a script.
#[derive(Debug)]
pub(crate) struct SessionStatus {
    status: EditorSessionStatus,
    transaction: Mutex<TransactionState>,
}

impl SessionStatus {
    pub(crate) fn new() -> Self {
        Self {
            status: EditorSessionStatus::new(),
            transaction: Mutex::new(TransactionState::Idle),
        }
    }

    pub(crate) fn state(&self) -> EditorSessionState {
        self.status.state()
    }

    /// Claim the session for one run.
    pub(crate) fn begin(&self) -> Result<(), DriverError> {
        self.status.begin()
    }

    pub(crate) fn finish(&self, transaction: TransactionState) {
        *self
            .transaction
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = transaction;
        self.status.finish();
    }

    pub(crate) fn lose(&self) {
        self.status.lose();
    }

    pub(crate) fn transaction(&self) -> TransactionState {
        *self
            .transaction
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_run_is_busy_and_a_lost_session_refuses_runs() {
        let status = SessionStatus::new();
        assert!(status.begin().is_ok());
        assert_eq!(status.begin(), Err(DriverError::EditorSessionBusy));

        status.finish(TransactionState::InTransaction);
        assert_eq!(status.state(), EditorSessionState::Ready);
        assert_eq!(status.transaction(), TransactionState::InTransaction);

        status.lose();
        assert!(matches!(status.begin(), Err(DriverError::ConnectionLost { .. })));
        status.finish(TransactionState::Idle);
        assert_eq!(
            status.state(),
            EditorSessionState::Lost,
            "a finished run revived a lost session"
        );
    }
}
