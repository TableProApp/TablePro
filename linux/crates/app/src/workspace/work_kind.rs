/// What a tab finished doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WorkKind {
    /// An editor tab's run.
    Query,
    Save,
    Export,
}
