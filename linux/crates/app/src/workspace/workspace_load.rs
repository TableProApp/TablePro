use super::{WorkspaceLoadError, WorkspaceRecord};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceLoad {
    Restored(WorkspaceRecord),
    /// Nothing was saved for this session yet.
    Empty,
    /// There is a file, and it cannot be used. The store refuses to
    /// write over it until it is reset.
    Blocked(WorkspaceLoadError),
}
