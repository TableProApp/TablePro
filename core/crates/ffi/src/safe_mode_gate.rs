use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{SafeModeLevel, WriteGate};

// What Safe Mode lets an editor run do before it is sent. The editor sends its text whole, so one refused statement
// keeps the whole run back.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct RunGate {
    pub refused: bool,
    // The statements to ask about first, each as it would run.
    pub confirm: Vec<String>,
    // One of them drops or empties a table, or changes every row of one.
    pub destructive: bool,
}

// Each batch is judged on its own, as the Linux app judges the batches it sends.
pub(crate) fn gate(sql: &str, grammar: SqlGrammar, level: SafeModeLevel) -> RunGate {
    let mut gate = RunGate::default();
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let mut strictest = StatementAccess::Read;
    for batch in plan.batches() {
        let Some(text) = sql.get(batch.range.clone()) else {
            continue;
        };
        // A Redis command's range is exact, and a blank Rust trims can be part of its last argument.
        let text = if grammar.is_sql() { text.trim() } else { text };
        if text.is_empty() {
            continue;
        }
        let access = statement_access(text, grammar);
        strictest = strictest.max(access);
        match level.gate(access) {
            WriteGate::Run => {}
            WriteGate::Refuse => gate.refused = true,
            WriteGate::Confirm => {
                gate.destructive |= access == StatementAccess::Destructive;
                // `GO 100` runs the batch a hundred times, which the question has to show.
                gate.confirm.push(match batch.repeat.get() {
                    1 => text.to_owned(),
                    times => format!("{text}\nGO {times}"),
                });
            }
        }
    }
    if sent_in_batches(sql, grammar, &plan) {
        return gate;
    }
    // The driver splits the text it gets with the session's own settings, so a reading of the whole that is stricter
    // than every batch decides, and the question shows the text as it is sent.
    let whole = statement_access(sql, grammar);
    if whole > strictest {
        match level.gate(whole) {
            WriteGate::Run => {}
            WriteGate::Refuse => gate.refused = true,
            WriteGate::Confirm => {
                gate.destructive |= whole == StatementAccess::Destructive;
                gate.confirm = vec![sql.trim().to_owned()];
            }
        }
    }
    gate
}

// The MySQL driver sends a script with a DELIMITER line and nothing left open as these batches, one at a time, so
// no server reads the text whole, DELIMITER lines and all.
fn sent_in_batches(sql: &str, grammar: SqlGrammar, plan: &ScriptPlan) -> bool {
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
    fn confirm_writes_asks_about_an_update_and_runs_a_select_at_once() {
        let update = gate(
            "UPDATE t SET a = 1 WHERE id = 2",
            SqlGrammar::PostgreSql,
            SafeModeLevel::ConfirmWrites,
        );
        let select = gate("SELECT * FROM t", SqlGrammar::PostgreSql, SafeModeLevel::ConfirmWrites);

        assert_eq!(update.confirm, ["UPDATE t SET a = 1 WHERE id = 2"]);
        assert!(!update.destructive);
        assert!(!update.refused);
        assert_eq!(select, RunGate::default());
    }

    #[test]
    fn each_statement_of_a_script_is_asked_about_on_its_own() {
        let run = gate(
            "SELECT 1; INSERT INTO t VALUES (1); SELECT 2; DELETE FROM t",
            SqlGrammar::MySql,
            SafeModeLevel::ConfirmWrites,
        );

        assert_eq!(run.confirm.len(), 2);
        assert!(run.confirm[0].starts_with("INSERT"));
        assert!(run.confirm[1].starts_with("DELETE"));
        assert!(run.destructive);
    }

    #[test]
    fn off_asks_only_before_a_destructive_statement() {
        let write = gate("INSERT INTO t VALUES (1)", SqlGrammar::Sqlite, SafeModeLevel::Off);
        let drop = gate("DROP TABLE t", SqlGrammar::Sqlite, SafeModeLevel::Off);

        assert_eq!(write, RunGate::default());
        assert_eq!(drop.confirm, ["DROP TABLE t"]);
        assert!(drop.destructive);
    }

    #[test]
    fn a_byte_order_mark_does_not_hide_a_sqlite_statement_from_the_question() {
        let drop = gate("\u{feff}DROP TABLE t", SqlGrammar::Sqlite, SafeModeLevel::Off);

        assert_eq!(drop.confirm.len(), 1);
        assert!(drop.destructive);
    }

    #[test]
    fn a_repeated_batch_shows_how_many_times_it_runs() {
        let run = gate(
            "UPDATE accounts SET balance = balance - 10 WHERE id = 1\nGO 100",
            SqlGrammar::MsSql,
            SafeModeLevel::ConfirmWrites,
        );

        assert_eq!(
            run.confirm,
            ["UPDATE accounts SET balance = balance - 10 WHERE id = 1\nGO 100"]
        );
    }

    #[test]
    fn read_only_keeps_back_a_script_with_one_write_and_asks_nothing() {
        let script = gate(
            "SELECT 1\nGO\nUPDATE t SET a = 1 WHERE id = 1\nGO\nSELECT 2",
            SqlGrammar::MsSql,
            SafeModeLevel::ReadOnly,
        );
        let read = gate("SELECT 1\nGO\nSELECT 2", SqlGrammar::MsSql, SafeModeLevel::ReadOnly);

        assert!(script.refused);
        assert!(script.confirm.is_empty());
        assert_eq!(read, RunGate::default());
    }

    #[test]
    fn a_mysql_executable_comment_is_read_as_the_server_reads_it() {
        // MySQL 8.0 skips the second comment past its nested `/* */` and runs the DROP after it.
        let script = "/*!40103 SET TIME_ZONE='+00:00' */;\nSELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '";

        let off = gate(script, SqlGrammar::MySql, SafeModeLevel::Off);
        let read_only = gate(script, SqlGrammar::MySql, SafeModeLevel::ReadOnly);

        assert_eq!(off.confirm, ["SELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '"]);
        assert!(off.destructive);
        assert!(read_only.refused);
    }

    #[test]
    fn a_text_only_the_whole_reading_shows_a_drop_in_is_asked_about_as_it_is_sent() {
        // A PostgreSQL session can turn backslash escapes on, and then the first string runs on and DROP is code.
        let sql = "SELECT 'x\\'; SELECT '; DROP TABLE t; --'";

        let run = gate(sql, SqlGrammar::PostgreSql, SafeModeLevel::ConfirmWrites);

        assert_eq!(run.confirm, [sql]);
        assert!(run.destructive);
    }

    #[test]
    fn a_mysql_read_script_with_delimiter_lines_runs_at_every_level() {
        let script = "DELIMITER //\nSELECT 1//\nDELIMITER ;\nSELECT 2;";

        for level in SafeModeLevel::ALL {
            assert_eq!(gate(script, SqlGrammar::MySql, level), RunGate::default(), "{level:?}");
        }
    }
}
