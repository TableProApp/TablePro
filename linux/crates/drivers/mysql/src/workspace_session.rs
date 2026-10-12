/// Run on every workspace connection right after it opens, and never on
/// an editor session.
///
/// With NO_BACKSLASH_ESCAPES set globally, a backslash in a string
/// literal would mean itself on some servers and an escape on others.
/// The DDL the app generates writes some literals that have no hex form
/// (`COMMENT '...'`), so the workspace pins the one reading those
/// literals were written for. sqlx sends no sql_mode of its own when
/// `pipes_as_concat` and `no_engine_substitution` are off, so this and
/// the time zone are the only session changes on top of the user's.
pub(crate) const WORKSPACE_SQL_MODE_STATEMENT: &str = "SET SESSION sql_mode = TRIM(BOTH ',' FROM \
     REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','))";

/// The zone workspace connections read TIMESTAMP in, so a value is the
/// instant it names whatever zone the server or the user is in.
pub(crate) const WORKSPACE_TIME_ZONE: &str = "+00:00";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_statement_removes_only_the_backslash_mode() {
        assert!(WORKSPACE_SQL_MODE_STATEMENT.starts_with("SET SESSION sql_mode = "));
        assert!(WORKSPACE_SQL_MODE_STATEMENT.contains("',NO_BACKSLASH_ESCAPES,'"));
        assert!(!WORKSPACE_SQL_MODE_STATEMENT.contains("PIPES_AS_CONCAT"));
    }
}
