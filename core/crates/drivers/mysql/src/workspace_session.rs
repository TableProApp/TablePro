/// Run on every workspace connection right after it opens, and never on
/// an editor session.
///
/// With NO_BACKSLASH_ESCAPES set globally, a backslash in a string
/// literal would mean itself on some servers and an escape on others.
/// The DDL the app generates writes some literals that have no hex form
/// (`COMMENT '...'`), so the workspace pins the one reading those
/// literals were written for.
///
/// STRICT_ALL_TABLES is added because a server without strict mode
/// stores what it can and only warns: a VARCHAR(5) keeps `abcde` of
/// `abcdefgh`, an unknown ENUM label becomes `''`, a TINYINT clamps 300
/// to 127, and a column made NOT NULL turns its NULLs into 0 or `''`.
/// Strict mode refuses each of these with an error, on every engine,
/// so a save, an import or a schema change either stores what it was
/// given or fails. sqlx sends no sql_mode of its own when
/// `pipes_as_concat` and `no_engine_substitution` are off, so this and
/// the time zone are the only session changes on top of the user's.
pub(crate) const WORKSPACE_SQL_MODE_STATEMENT: &str = "SET SESSION sql_mode = TRIM(BOTH ',' FROM \
     CONCAT(REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','), 'STRICT_ALL_TABLES'))";

/// The zone workspace connections read TIMESTAMP in, so a value is the
/// instant it names whatever zone the server or the user is in.
pub(crate) const WORKSPACE_TIME_ZONE: &str = "+00:00";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_statement_removes_the_backslash_mode_and_adds_strict_mode() {
        assert!(WORKSPACE_SQL_MODE_STATEMENT.starts_with("SET SESSION sql_mode = "));
        assert!(WORKSPACE_SQL_MODE_STATEMENT.contains("',NO_BACKSLASH_ESCAPES,'"));
        assert!(WORKSPACE_SQL_MODE_STATEMENT.contains("'STRICT_ALL_TABLES'"));
        assert!(!WORKSPACE_SQL_MODE_STATEMENT.contains("PIPES_AS_CONCAT"));
    }
}
