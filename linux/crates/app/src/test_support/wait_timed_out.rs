use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("the condition did not hold within {timeout:?}")]
pub(crate) struct WaitTimedOut {
    pub timeout: Duration,
}
