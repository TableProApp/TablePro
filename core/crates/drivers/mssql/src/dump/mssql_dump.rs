use tablepro_core::dump::{DumpDialect, DumpStatement};

/// How SQL Server writes a dump: every statement a batch of its own,
/// since CREATE VIEW, FUNCTION, PROCEDURE and TRIGGER must each open one,
/// and sqlcmd and SSMS send a file a `GO` at a time.
#[derive(Debug)]
pub(crate) struct MssqlDump;

impl DumpDialect for MssqlDump {
    /// The settings SMO scripts under; a module made under others is
    /// framed in its own.
    fn header(&self) -> String {
        ["SET ANSI_NULLS ON", "SET QUOTED_IDENTIFIER ON"]
            .into_iter()
            .map(|sql| self.statement(&DumpStatement::new(sql)))
            .collect()
    }

    /// A batch of its own: SQL Server keeps a module's text from the
    /// start of its batch, so a comment there would join the module.
    fn comment(&self, text: &str) -> String {
        format!("\n-- {text}\nGO\n")
    }

    fn statement(&self, statement: &DumpStatement) -> String {
        format!("{}\nGO\n", statement.sql)
    }

    fn identity_insert(&self, table_sql: &str, on: bool) -> Option<String> {
        let state = if on { "ON" } else { "OFF" };
        Some(format!("SET IDENTITY_INSERT {table_sql} {state}"))
    }

    fn transactional_ddl(&self) -> bool {
        true
    }

    fn begin(&self) -> &'static str {
        "BEGIN TRANSACTION"
    }

    fn commit(&self) -> &'static str {
        "COMMIT TRANSACTION"
    }

    fn rollback(&self) -> &'static str {
        "ROLLBACK TRANSACTION"
    }

    /// Without it an error can roll back only its own statement and leave
    /// the transaction open, so the rest of the file would still commit.
    fn after_begin(&self) -> &'static [&'static str] {
        &["SET XACT_ABORT ON"]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_statement_ends_its_batch() {
        assert_eq!(
            MssqlDump.header(),
            "SET ANSI_NULLS ON\nGO\nSET QUOTED_IDENTIFIER ON\nGO\n"
        );
        assert_eq!(
            MssqlDump.statement(&DumpStatement::body("CREATE PROCEDURE p AS SELECT 1; -- done")),
            "CREATE PROCEDURE p AS SELECT 1; -- done\nGO\n"
        );
        assert_eq!(
            MssqlDump.statement(&DumpStatement::new("INSERT INTO [t] ([a]) VALUES\n(1)")),
            "INSERT INTO [t] ([a]) VALUES\n(1)\nGO\n"
        );
    }

    #[test]
    fn an_identity_insert_is_turned_on_and_off_by_name() {
        assert_eq!(
            MssqlDump.identity_insert("[app].[t]", true).as_deref(),
            Some("SET IDENTITY_INSERT [app].[t] ON")
        );
        assert_eq!(
            MssqlDump.identity_insert("[app].[t]", false).as_deref(),
            Some("SET IDENTITY_INSERT [app].[t] OFF")
        );
    }

    #[test]
    fn a_load_is_one_transaction_that_aborts_on_any_error() {
        assert!(MssqlDump.transactional_ddl());
        assert_eq!(MssqlDump.begin(), "BEGIN TRANSACTION");
        assert_eq!(MssqlDump.commit(), "COMMIT TRANSACTION");
        assert_eq!(MssqlDump.rollback(), "ROLLBACK TRANSACTION");
        assert_eq!(MssqlDump.after_begin(), ["SET XACT_ABORT ON"]);
    }
}
