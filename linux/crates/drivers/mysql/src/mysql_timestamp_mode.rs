/// What a TIMESTAMP value means on the session it was read on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum MySqlTimestampMode {
    /// A workspace session's zone is pinned to UTC, so the value is an
    /// instant and keeps its offset.
    WorkspaceUtc,
    /// An editor session reads in the server's own zone, which the
    /// value does not carry, so it stays the wall time it showed.
    SessionLocal,
}
