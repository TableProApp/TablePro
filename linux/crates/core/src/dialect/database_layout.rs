/// How the server's databases stand to the catalog a connection reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseLayout {
    /// A connection reaches one database: a file, or numbered databases
    /// of keys.
    Single,
    /// The server's databases are the schemas the catalog lists, so one
    /// connection reads every one of them.
    AsSchemas,
    /// Each database holds schemas of its own, and a connection's catalog
    /// describes only the database it opened.
    WithSchemas,
}
