/// How a table is emptied.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct TruncateTableOptions {
    /// Empty the tables whose foreign keys point at it too. Only an
    /// engine with `truncate_cascade` takes it.
    pub cascade: bool,
    /// Start the table's numbering again. Only an engine with
    /// `truncate_restart_identity` takes it.
    pub restart_identity: bool,
    /// Run it on every server of this cluster. Only an engine with
    /// `on_cluster` takes it.
    pub cluster: Option<String>,
}
