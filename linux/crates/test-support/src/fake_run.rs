use std::time::Duration;

use tablepro_core::{DriverError, ResultEvent, RunEnd, TransactionState};

/// How long a scripted run takes before it sends its events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunWait {
    None,
    /// Takes this long unless the run is stopped first.
    For(Duration),
    /// Only a cancel or the run's deadline ends it.
    UntilStopped,
}

/// One scripted run of a `FakeEditorSession`.
#[derive(Debug, Clone)]
pub struct FakeRun {
    pub events: Vec<ResultEvent>,
    pub wait: RunWait,
    /// `Err` is the session itself failing, which `run` returns as an
    /// error; `Ok` is how the statements ended.
    pub end: Result<RunEnd, DriverError>,
    pub transaction_state: TransactionState,
}

impl FakeRun {
    pub fn completed(events: Vec<ResultEvent>) -> Self {
        Self {
            events,
            wait: RunWait::None,
            end: Ok(RunEnd::Completed),
            transaction_state: TransactionState::Idle,
        }
    }

    /// A statement the server refused, which the results list shows.
    pub fn failed(error: DriverError) -> Self {
        Self {
            end: Ok(RunEnd::Failed(error)),
            ..Self::completed(Vec::new())
        }
    }

    /// The session failing, such as `EditorSessionBusy` or a lost
    /// connection.
    pub fn session_error(error: DriverError) -> Self {
        Self {
            end: Err(error),
            ..Self::completed(Vec::new())
        }
    }

    pub fn until_stopped() -> Self {
        Self {
            wait: RunWait::UntilStopped,
            ..Self::completed(Vec::new())
        }
    }

    pub fn taking(self, duration: Duration) -> Self {
        Self {
            wait: RunWait::For(duration),
            ..self
        }
    }

    pub fn leaving(self, transaction_state: TransactionState) -> Self {
        Self {
            transaction_state,
            ..self
        }
    }
}
