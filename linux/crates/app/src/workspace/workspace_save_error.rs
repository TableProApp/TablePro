use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WorkspaceSaveError {
    /// The saved tabs could not be read, and writing would destroy them.
    #[error("the saved tabs could not be read, so they are not written over")]
    Blocked,
    #[error("could not save the open tabs: {0}")]
    Write(String),
    #[error("could not move the saved tabs aside: {0}")]
    MoveAside(String),
    #[error("the workspace writer has stopped")]
    WriterStopped,
}
