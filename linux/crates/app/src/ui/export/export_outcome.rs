use gtk4::glib;
use tablepro_session::runtime::TaskFailure;
use thiserror::Error;

use super::{AbortOutcome, ExportStreamFailure};

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

#[derive(Debug, Error)]
pub(crate) enum ExportFailure {
    #[error(transparent)]
    Stream(#[from] ExportStreamFailure),
    #[error(transparent)]
    File(#[from] glib::Error),
    #[error(transparent)]
    Task(#[from] TaskFailure),
}
