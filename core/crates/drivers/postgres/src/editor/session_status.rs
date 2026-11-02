use std::sync::Mutex;
use std::sync::atomic::{AtomicU8, Ordering};

use tablepro_core::{DriverError, EditorSessionState, LossPhase, TransactionState};

const READY: u8 = 0;
const RUNNING: u8 = 1;
const LOST: u8 = 2;

/// What the session handle can answer without asking the actor, which
/// may be busy running a script.
#[derive(Debug)]
pub(crate) struct SessionStatus {
    state: AtomicU8,
    transaction: Mutex<TransactionState>,
}

impl SessionStatus {
    pub(crate) fn new() -> Self {
        Self {
            state: AtomicU8::new(READY),
            transaction: Mutex::new(TransactionState::Idle),
        }
    }

    pub(crate) fn state(&self) -> EditorSessionState {
        match self.state.load(Ordering::SeqCst) {
            READY => EditorSessionState::Ready,
            RUNNING => EditorSessionState::Running,
            _ => EditorSessionState::Lost,
        }
    }

    /// Claim the session for one run.
    pub(crate) fn begin(&self) -> Result<(), DriverError> {
        match self
            .state
            .compare_exchange(READY, RUNNING, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) => Ok(()),
            Err(RUNNING) => Err(DriverError::EditorSessionBusy),
            Err(_) => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
        }
    }

    pub(crate) fn finish(&self, transaction: TransactionState) {
        *self
            .transaction
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = transaction;
        let _ = self
            .state
            .compare_exchange(RUNNING, READY, Ordering::SeqCst, Ordering::SeqCst);
    }

    pub(crate) fn lose(&self) {
        self.state.store(LOST, Ordering::SeqCst);
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
