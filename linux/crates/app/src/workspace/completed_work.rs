use uuid::Uuid;

use super::{WorkKind, WorkOutcome};

/// A run, save or export that ended in one of the workspace's tabs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompletedWork {
    pub tab: Uuid,
    pub kind: WorkKind,
    pub outcome: WorkOutcome,
}
