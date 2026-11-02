/// The SQL that defines a routine, a sequence or a trigger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectDefinition {
    pub sql: String,
    /// The database `sql` has to run in, where the server's text names
    /// none, as MySQL's `SHOW CREATE` does. `None` when it names the
    /// object in full, so any tab of the connection can run it.
    pub database: Option<String>,
    /// Why running `sql` in an editor tab would not make the object as it
    /// is. `None` when it would.
    pub refusal: Option<EditorRefusal>,
}

/// Why a definition does not open in the editor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorRefusal {
    /// The editor would end a batch inside the text, as at a SQL Server
    /// body line that is only `GO`, and run the rest on its own.
    SplitsApart,
    /// The object was made under session settings a new editor tab does
    /// not run with, such as another `sql_mode` or `QUOTED_IDENTIFIER`,
    /// which decide how its body reads.
    OtherSettings,
    /// The object is made along with another, as an identity column's
    /// sequence is with its column.
    MadeWithOther,
}
