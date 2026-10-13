/// How a table is dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct DropTableOptions {
    pub if_exists: bool,
    /// Drop the objects that depend on the table too. Only an engine
    /// with `drop_table_cascade` takes it.
    pub cascade: bool,
}
