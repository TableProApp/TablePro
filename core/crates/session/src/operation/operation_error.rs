use tablepro_core::browse::BrowseSqlError;
use tablepro_core::dml::BuildSqlError;
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{DriverError, ErrorCategory};
use thiserror::Error;

use crate::runtime::{TaskFailure, TaskPanic};

/// Why an operation produced no value.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum OperationError {
    #[error(transparent)]
    Driver(#[from] DriverError),
    #[error(transparent)]
    Sql(#[from] SqlBuildError),
    #[error(transparent)]
    Browse(#[from] BrowseSqlError),
    #[error(transparent)]
    Build(#[from] BuildSqlError),
    #[error(transparent)]
    Panicked(#[from] TaskPanic),
    /// The caller stopped it.
    #[error("cancelled")]
    Cancelled,
    /// The session is shutting down, or has no connection left.
    #[error("the session is closed")]
    Closed,
}

impl OperationError {
    /// The driver error's category, when the driver is what failed.
    pub fn category(&self) -> Option<ErrorCategory> {
        match self {
            Self::Driver(error) => Some(error.category()),
            Self::Sql(_) | Self::Browse(_) | Self::Build(_) | Self::Panicked(_) | Self::Cancelled | Self::Closed => {
                None
            }
        }
    }
}

/// A task that never answered is reported like the operation it ran: a
/// panic as the bug it is, an abort as the app stopping the work.
impl From<TaskFailure> for OperationError {
    fn from(failure: TaskFailure) -> Self {
        match failure {
            TaskFailure::Panicked(panic) => Self::Panicked(panic),
            TaskFailure::Aborted => Self::Cancelled,
        }
    }
}
