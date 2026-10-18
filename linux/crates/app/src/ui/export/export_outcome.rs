use gtk4::glib;
use tablepro_session::OperationError;
use tablepro_session::runtime::TaskFailure;
use thiserror::Error;

use super::{AbortOutcome, ExportStreamFailure, OpenError};
use crate::workspace::WorkOutcome;

/// How an export ended.
#[derive(Debug)]
pub(crate) enum ExportOutcome {
    Exported {
        rows: u64,
    },
    Stopped(AbortOutcome),
    /// `file` says what became of the file, when the export had opened
    /// it.
    Failed {
        failure: ExportFailure,
        file: Option<AbortOutcome>,
    },
}

impl From<&ExportOutcome> for WorkOutcome {
    fn from(outcome: &ExportOutcome) -> Self {
        match outcome {
            ExportOutcome::Exported { .. } => Self::Succeeded,
            ExportOutcome::Stopped(_) => Self::Cancelled,
            ExportOutcome::Failed { .. } => Self::Failed,
        }
    }
}

#[derive(Debug, Error)]
pub(crate) enum ExportFailure {
    #[error(transparent)]
    Stream(#[from] ExportStreamFailure),
    #[error(transparent)]
    File(#[from] glib::Error),
    #[error(transparent)]
    Task(#[from] TaskFailure),
    /// Reading the table failed.
    #[error("reading the table failed: {0}")]
    Table(OperationError),
    /// Running an editor's statement again failed. It ran on a
    /// connection of its own, which the alert has to explain.
    #[error("running the statement again failed: {0}")]
    Statement(OperationError),
    #[error("another export is writing to this file")]
    InUse,
}

impl From<OpenError> for ExportFailure {
    fn from(error: OpenError) -> Self {
        match error {
            OpenError::InUse => Self::InUse,
            OpenError::File(error) => Self::File(error),
        }
    }
}
