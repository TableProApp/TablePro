use super::SqlGrammar;
use super::script::{ScriptPlan, ScriptTokenKind};

/// Words that add, rename or remove what the sidebar lists. They count
/// anywhere in a statement: a SQL Server batch needs no `;` between its
/// statements, and these words appear in no other kind of statement.
const SCHEMA_VERBS: [&str; 7] = ["CREATE", "ALTER", "DROP", "RENAME", "ATTACH", "DETACH", "IMPORT"];

/// DDL run inside a transaction reaches the window's own connection only
/// once it commits.
const TRANSACTION_ENDS: [&str; 2] = ["COMMIT", "END"];

/// Whether running `text` can change the tables the catalog lists, read
/// every way the server may read it. A commit counts as the statement's
/// first word, and `SELECT … INTO` counts too, since PostgreSQL and SQL
/// Server create its target table.
///
/// On an engine of keys every write can add or remove one, so the keys
/// are listed again after any command that writes, or that commits a
/// transaction.
pub fn changes_catalog(text: &str, grammar: SqlGrammar) -> bool {
    match grammar {
        SqlGrammar::Redis => return super::redis::may_change_keys(text),
        SqlGrammar::Mongo => return super::mongo::may_change_catalog(text),
        _ => {}
    }
    ScriptPlan::server_readings(text, grammar).is_none_or(|mut plans| plans.any(|plan| plan_changes(text, &plan)))
}

fn plan_changes(text: &str, plan: &ScriptPlan) -> bool {
    let is = |word: &str, set: &[&str]| set.iter().any(|verb| word.eq_ignore_ascii_case(verb));
    plan.statements().iter().any(|statement| {
        let words: Vec<&str> = plan
            .tokens(statement.range.clone())
            .filter(|token| token.kind == ScriptTokenKind::Word)
            .filter_map(|token| text.get(token.range))
            .collect();
        let Some(first) = words.first() else {
            return false;
        };
        words.iter().any(|word| is(word, &SCHEMA_VERBS))
            || is(first, &TRANSACTION_ENDS)
            || (is(first, &["SELECT", "WITH"]) && words.iter().any(|word| is(word, &["INTO"])))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ddl_changes_the_catalog_in_every_grammar() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "CREATE TABLE orders (id int)",
                "create view v as select 1",
                "ALTER TABLE orders ADD note text",
                "DROP TABLE orders",
                "-- a note first\nCREATE INDEX i ON orders (id)",
                "SELECT 1; DROP TABLE orders",
            ] {
                assert!(changes_catalog(sql, grammar), "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn every_write_changes_the_keys() {
        for text in ["SET k 1", "DEL k", "RENAME a b", "GET k\nFLUSHDB", "EXEC"] {
            assert!(changes_catalog(text, SqlGrammar::Redis), "{text}");
        }
        for text in ["GET k", "SCAN 0", "HGETALL h"] {
            assert!(!changes_catalog(text, SqlGrammar::Redis), "{text}");
        }
    }

    #[test]
    fn reads_and_row_writes_leave_it_alone() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "SELECT * FROM orders",
                "INSERT INTO orders VALUES (1)",
                "UPDATE orders SET id = 2",
                "DELETE FROM orders",
                "SELECT 'CREATE TABLE x' AS text",
                "-- DROP TABLE orders\nSELECT 1",
                "",
            ] {
                assert!(!changes_catalog(sql, grammar), "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn ddl_after_another_statement_in_a_sql_server_batch_counts() {
        assert!(changes_catalog(
            "INSERT INTO log VALUES (1)\nCREATE TABLE orders (id int)",
            SqlGrammar::MsSql
        ));
    }

    #[test]
    fn a_case_end_is_not_a_commit() {
        assert!(!changes_catalog(
            "SELECT CASE WHEN id > 1 THEN 'a' END FROM orders",
            SqlGrammar::PostgreSql
        ));
    }

    #[test]
    fn a_commit_publishes_ddl_run_in_a_transaction() {
        assert!(changes_catalog("COMMIT", SqlGrammar::PostgreSql));
        assert!(changes_catalog("END", SqlGrammar::PostgreSql));
        assert!(changes_catalog("COMMIT TRANSACTION", SqlGrammar::MsSql));
        assert!(!changes_catalog("BEGIN", SqlGrammar::PostgreSql));
    }

    #[test]
    fn select_into_creates_its_target() {
        assert!(changes_catalog("SELECT * INTO archive FROM orders", SqlGrammar::MsSql));
        assert!(changes_catalog(
            "SELECT id INTO TEMP t FROM orders",
            SqlGrammar::PostgreSql
        ));
        assert!(!changes_catalog("SELECT id FROM orders", SqlGrammar::PostgreSql));
    }

    #[test]
    fn ddl_only_some_mysql_server_versions_run_counts() {
        for sql in [
            "/*!50001 CREATE VIEW v AS SELECT 1 */",
            "SELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '",
            r"SELECT 'C:\'; DROP TABLE orders; -- '",
        ] {
            assert!(changes_catalog(sql, SqlGrammar::MySql), "{sql}");
        }
    }

    #[test]
    fn sqlite_attach_and_rename_count() {
        assert!(changes_catalog("ATTACH DATABASE 'x.db' AS x", SqlGrammar::Sqlite));
        assert!(changes_catalog("RENAME TABLE a TO b", SqlGrammar::MySql));
    }
}
