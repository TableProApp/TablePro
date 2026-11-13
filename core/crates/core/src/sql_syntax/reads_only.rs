use super::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use super::{SqlGrammar, StatementAccess, statement_access};

// Every statement of the text only reads, as Safe Mode reads it: each batch on its own, then the text whole as the
// driver splits it. Empty text, or text that leaves a string, name or comment open, is no read. A revealed query tab
// runs again only when this holds, so a write never repeats.
pub fn reads_only(sql: &str, grammar: SqlGrammar) -> bool {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    if !plan.diagnostics().is_empty() {
        return false;
    }
    let mut statements = 0;
    for batch in plan.batches() {
        let Some(text) = sql.get(batch.range.clone()) else {
            continue;
        };
        // A Redis command's range is exact, and a blank Rust trims can be part of its last argument.
        let text = if grammar.is_sql() { text.trim() } else { text };
        if text.is_empty() {
            continue;
        }
        statements += 1;
        if statement_access(text, grammar) != StatementAccess::Read {
            return false;
        }
    }
    statements > 0 && (sent_in_batches(sql, grammar, &plan) || statement_access(sql, grammar) == StatementAccess::Read)
}

// The MySQL driver sends a script with a DELIMITER line and nothing left open as its batches, one at a time, so no
// server reads the text whole, DELIMITER lines and all.
pub fn sent_in_batches(sql: &str, grammar: SqlGrammar, plan: &ScriptPlan) -> bool {
    grammar == SqlGrammar::MySql
        && plan.diagnostics().is_empty()
        && plan
            .tokens(0..sql.len())
            .any(|token| token.kind == ScriptTokenKind::Directive)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_alone_or_together_are_a_read() {
        for sql in [
            "SELECT 1",
            "SELECT 1; SELECT 2;",
            "  WITH t AS (SELECT 1) SELECT * FROM t  ",
            "SHOW TABLES",
            "EXPLAIN SELECT * FROM orders",
        ] {
            assert!(reads_only(sql, SqlGrammar::PostgreSql), "{sql}");
        }
    }

    #[test]
    fn a_write_anywhere_in_the_text_is_no_read() {
        for sql in [
            "DELETE FROM t",
            "SELECT 1; DELETE FROM t",
            "SELECT 1;\nSELECT 2;\nUPDATE t SET a = 1 WHERE id = 1",
            "WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone",
            "SELECT 1; DROP TABLE t; SELECT 2",
            "EXPLAIN ANALYZE DELETE FROM t",
        ] {
            assert!(!reads_only(sql, SqlGrammar::PostgreSql), "{sql}");
        }
    }

    #[test]
    fn empty_or_open_text_is_no_read() {
        for sql in ["", "   \n", ";", "SELECT 'open", "SELECT 1 /* open"] {
            assert!(!reads_only(sql, SqlGrammar::PostgreSql), "{sql:?}");
        }
    }

    #[test]
    fn each_engine_splits_by_its_own_rules() {
        assert!(reads_only("SELECT 1\nGO\nSELECT 2\nGO", SqlGrammar::MsSql));
        assert!(!reads_only(
            "SELECT 1\nGO\nUPDATE t SET a = 1 WHERE id = 1\nGO",
            SqlGrammar::MsSql
        ));
        assert!(reads_only(
            "DELIMITER //\nSELECT 1//\nDELIMITER ;\nSELECT 2;",
            SqlGrammar::MySql
        ));
        assert!(!reads_only(
            "DELIMITER //\nSELECT 1//\nINSERT INTO t VALUES (1)//",
            SqlGrammar::MySql
        ));
        assert!(reads_only("SELECT 1; SELECT 2", SqlGrammar::Sqlite));
        assert!(!reads_only("SELECT 1; INSERT INTO t VALUES (1)", SqlGrammar::Sqlite));
    }
}
