use super::DumpStatement;

/// How one engine writes a SQL dump and runs one back.
///
/// Reached through `SqlDialect::dump`, which is `None` for an engine the
/// app does not dump. A file written here loads with the engine's own
/// client as well as with TablePro's import.
pub trait DumpDialect: Send + Sync + std::fmt::Debug {
    /// What follows TablePro's comment lines at the top of the file.
    fn header(&self) -> String {
        String::new()
    }

    fn footer(&self) -> String {
        String::new()
    }

    /// The comment line that names the object after it, `text` free of
    /// line breaks already.
    fn comment(&self, text: &str) -> String {
        format!("\n-- {text}\n")
    }

    /// One statement as the engine's client reads it from a file.
    fn statement(&self, statement: &DumpStatement) -> String {
        format!("{};\n", statement.sql)
    }

    /// The statement that lets an INSERT set the table's identity column,
    /// or stops letting it.
    fn identity_insert(&self, _table_sql: &str, _on: bool) -> Option<String> {
        None
    }

    /// Whether a CREATE or DROP rolls back with its transaction, so an
    /// import can run as one.
    fn transactional_ddl(&self) -> bool {
        false
    }

    fn begin(&self) -> &'static str {
        "BEGIN"
    }

    fn commit(&self) -> &'static str {
        "COMMIT"
    }

    fn rollback(&self) -> &'static str {
        "ROLLBACK"
    }

    /// What runs right before `begin` in an import that is one
    /// transaction, for a setting the engine takes only outside one.
    fn before_begin(&self) -> &'static [&'static str] {
        &[]
    }

    /// What runs right after `begin` in an import that is one
    /// transaction.
    fn after_begin(&self) -> &'static [&'static str] {
        &[]
    }
}
