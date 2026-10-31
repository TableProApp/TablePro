use std::path::PathBuf;

use tablepro_storage::DraftScope;
use tokio::sync::oneshot;

use super::{OpenSessionsRecord, WorkspaceRecord, WorkspaceSaveError};

/// What the writer task is asked to do, in the order it was asked.
pub(super) enum WriteJob {
    Write {
        path: PathBuf,
        record: WorkspaceRecord,
    },
    OpenSessions {
        path: PathBuf,
        record: OpenSessionsRecord,
    },
    /// Answered once every record queued before it for `path` is on
    /// disk, with how the last write of that file went.
    Flush {
        path: PathBuf,
        written: oneshot::Sender<Result<(), WorkspaceSaveError>>,
    },
    /// Delete the file, every copy of it moved aside and the drafts in
    /// `drafts`, for a connection that was deleted. A record queued for
    /// `path` in the same round is dropped rather than written.
    Purge {
        path: PathBuf,
        drafts: DraftScope,
        purged: oneshot::Sender<Result<(), WorkspaceSaveError>>,
    },
    /// Purge, as `Purge` does, every session whose name starts with
    /// `prefix`: those found in `dir` as a file or a copy moved aside,
    /// and those with drafts only.
    PurgeNamed {
        dir: PathBuf,
        prefix: String,
        purged: oneshot::Sender<Result<(), WorkspaceSaveError>>,
    },
}
