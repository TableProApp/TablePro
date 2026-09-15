/// What happened to the connection a write was running on.
///
/// The fate decides what the write outcome can be: a session that
/// rolled back cleanly leaves nothing applied, and one that was
/// discarded mid-transaction leaves the same, because a commit never
/// written cannot land once the session is gone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionFate {
    RolledBack,
    Discarded,
    /// The rollback itself did not finish, so `executed` statements may
    /// still be there.
    RollbackIncomplete {
        executed: usize,
    },
}
