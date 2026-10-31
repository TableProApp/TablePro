use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{SafeModeLevel, WriteGate};

use super::script_runner::RunBatch;

/// A run as Safe Mode lets it start: each batch read on its own, the
/// ones Read-Only keeps back marked, and the ones to ask about first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GatedRun {
    pub batches: Vec<RunBatch>,
    pub confirm: Vec<String>,
    pub destructive: bool,
}

pub(super) fn gate(mut batches: Vec<RunBatch>, grammar: SqlGrammar, level: SafeModeLevel) -> GatedRun {
    let mut confirm = Vec::new();
    let mut destructive = false;
    for batch in &mut batches {
        let access = statement_access(&batch.text, grammar);
        match level.gate(access) {
            WriteGate::Run => {}
            WriteGate::Refuse => batch.refused = true,
            WriteGate::Confirm => {
                destructive |= access == StatementAccess::Destructive;
                // `GO 100` runs the batch a hundred times, which the
                // question has to show.
                confirm.push(match batch.repeat {
                    0 | 1 => batch.text.clone(),
                    times => format!("{}\nGO {times}", batch.text),
                });
            }
        }
    }
    GatedRun {
        batches,
        confirm,
        destructive,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::editor::run_scope::ScopedText;
    use crate::ui::editor::script_runner::plan_batches;

    fn gated(text: &str, grammar: SqlGrammar, level: SafeModeLevel) -> GatedRun {
        let scoped = ScopedText {
            text: text.to_owned(),
            base_char: 0,
        };
        gate(plan_batches(&scoped, grammar, 0).0, grammar, level)
    }

    #[test]
    fn confirm_writes_asks_about_an_update_and_runs_a_select_at_once() {
        let update = gated(
            "UPDATE t SET a = 1 WHERE id = 2",
            SqlGrammar::PostgreSql,
            SafeModeLevel::ConfirmWrites,
        );
        let select = gated("SELECT * FROM t", SqlGrammar::PostgreSql, SafeModeLevel::ConfirmWrites);

        assert_eq!(update.confirm, ["UPDATE t SET a = 1 WHERE id = 2"]);
        assert!(!update.destructive);
        assert!(select.confirm.is_empty());
        assert!(select.batches.iter().all(|batch| !batch.refused));
    }

    #[test]
    fn each_statement_of_a_script_is_judged_on_its_own() {
        let run = gated(
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
        let write = gated("INSERT INTO t VALUES (1)", SqlGrammar::Sqlite, SafeModeLevel::Off);
        let drop = gated("DROP TABLE t", SqlGrammar::Sqlite, SafeModeLevel::Off);

        assert!(write.confirm.is_empty());
        assert_eq!(drop.confirm, ["DROP TABLE t"]);
        assert!(drop.destructive);
    }

    #[test]
    fn a_byte_order_mark_does_not_hide_a_sqlite_statement_from_the_question() {
        // SQLite reads U+FEFF as a space where a token starts, so both
        // statements run as written without the mark.
        let drop = gated("\u{feff}DROP TABLE t", SqlGrammar::Sqlite, SafeModeLevel::Off);
        let delete = gated(
            "WITH stale AS (SELECT 1) \u{feff}DELETE FROM t",
            SqlGrammar::Sqlite,
            SafeModeLevel::ConfirmWrites,
        );

        assert_eq!(drop.confirm.len(), 1);
        assert!(drop.destructive);
        assert_eq!(delete.confirm, ["WITH stale AS (SELECT 1) \u{feff}DELETE FROM t"]);
        assert!(delete.destructive);
    }

    #[test]
    fn a_repeated_batch_shows_how_many_times_it_runs() {
        let run = gated(
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
    fn a_mysql_executable_comment_is_sent_and_read_as_the_server_reads_it() {
        // MySQL 8.0 skips the second comment past its nested `/* */` and
        // runs the DROP after it.
        let script = "/*!40103 SET TIME_ZONE='+00:00' */;\nSELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '";

        let off = gated(script, SqlGrammar::MySql, SafeModeLevel::Off);
        let read_only = gated(script, SqlGrammar::MySql, SafeModeLevel::ReadOnly);

        let texts: Vec<&str> = off.batches.iter().map(|batch| batch.text.as_str()).collect();
        assert_eq!(
            texts,
            [
                "/*!40103 SET TIME_ZONE='+00:00' */",
                "SELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '"
            ]
        );
        assert_eq!(off.confirm, ["SELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '"]);
        assert!(off.destructive);
        assert!(read_only.batches.iter().all(|batch| batch.refused));
    }

    #[test]
    fn a_batch_the_driver_splits_again_is_read_piece_by_piece() {
        // The driver reads the batch's second line as a DELIMITER line and
        // sends the last line alone, where MySQL 8.0 runs the DROP.
        let script = "DELIMITER //\nSELECT 1;\nDELIMITER ; /*!99999 '*/ `' */\n\
                      SELECT 1 /*!99999 ' */ ; DROP TABLE t; -- ` ' */\n//";

        let run = gated(script, SqlGrammar::MySql, SafeModeLevel::Off);

        assert_eq!(run.batches.len(), 1);
        assert!(run.destructive);
    }

    #[test]
    fn read_only_keeps_back_every_write_and_asks_nothing() {
        let run = gated(
            "SELECT 1\nGO\nUPDATE t SET a = 1 WHERE id = 1\nGO\nSELECT 2",
            SqlGrammar::MsSql,
            SafeModeLevel::ReadOnly,
        );

        let refused: Vec<bool> = run.batches.iter().map(|batch| batch.refused).collect();
        assert_eq!(refused, [false, true, false]);
        assert!(run.confirm.is_empty());
    }
}
