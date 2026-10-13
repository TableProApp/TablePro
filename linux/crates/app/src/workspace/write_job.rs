use std::path::PathBuf;

use tokio::sync::oneshot;

use super::{WorkspaceRecord, WorkspaceSaveError};

/// What the writer task is asked to do, in the order it was asked.
pub(super) enum WriteJob {
    Write {
        path: PathBuf,
        record: WorkspaceRecord,
    },
    /// Answered once every record queued before it for `path` is on
    /// disk, with how the last write of that file went.
    Flush {
        path: PathBuf,
        written: oneshot::Sender<Result<(), WorkspaceSaveError>>,
    },
}
