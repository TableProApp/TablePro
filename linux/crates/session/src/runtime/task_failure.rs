use thiserror::Error;

use super::TaskPanic;

/// Why a task produced no value.
///
/// A panic and an abort are separated because the UI reacts
/// differently: a panic is a bug worth logging loudly, while an abort is
/// the app's own doing when a view goes away.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TaskFailure {
    #[error("a background task panicked: {0}")]
    Panicked(TaskPanic),
    #[error("a background task was cancelled")]
    Aborted,
}

impl TaskFailure {
    pub fn is_panic(&self) -> bool {
        matches!(self, Self::Panicked(_))
    }
}
