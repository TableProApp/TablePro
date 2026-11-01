/// The SQL that recreates a routine, a sequence or a trigger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectDefinition {
    pub sql: String,
    /// The database `sql` has to run in, where the server's text names
    /// none, as MySQL's `SHOW CREATE` does. `None` when it names the
    /// object in full, so any tab of the connection can run it.
    pub database: Option<String>,
    /// False when running `sql` in an editor tab would not make the
    /// object as it is, as when a SQL Server module's body holds a line
    /// that is only `GO`, where the editor would end a batch.
    pub opens_in_editor: bool,
}
