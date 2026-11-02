use std::sync::atomic::{AtomicU8, Ordering};

use tablepro_core::{DriverError, EditorSessionState, LossPhase};

const READY: u8 = 0;
const RUNNING: u8 = 1;
const LOST: u8 = 2;

/// What an editor session handle answers without waiting for a run.
#[derive(Debug)]
pub(crate) struct SessionStatus {
    state: AtomicU8,
}

impl SessionStatus {
    pub(crate) fn new() -> Self {
        Self {
            state: AtomicU8::new(READY),
        }
    }

    pub(crate) fn state(&self) -> EditorSessionState {
        match self.state.load(Ordering::SeqCst) {
            READY => EditorSessionState::Ready,
            RUNNING => EditorSessionState::Running,
            _ => EditorSessionState::Lost,
        }
    }

    /// Claim the session for one run: the server refuses a second query
    /// on a session that is still running one.
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

    pub(crate) fn finish(&self) {
        let _ = self
            .state
            .compare_exchange(RUNNING, READY, Ordering::SeqCst, Ordering::SeqCst);
    }

    pub(crate) fn lose(&self) {
        self.state.store(LOST, Ordering::SeqCst);
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

        status.finish();
        assert_eq!(status.state(), EditorSessionState::Ready);

        status.lose();
        assert!(matches!(status.begin(), Err(DriverError::ConnectionLost { .. })));
        status.finish();
        assert_eq!(
            status.state(),
            EditorSessionState::Lost,
            "a finished run revived a lost session"
        );
    }
}
