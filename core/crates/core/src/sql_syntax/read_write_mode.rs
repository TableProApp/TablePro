use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{ScriptPlan, ScriptToken};
use crate::sql_syntax::statement_access::{
    CLIENT_SPLITS, Code, Kind, code_of, decodes_unicode_names, is, may_be_space, spelled_in_escapes, split_at_blanks,
};
use crate::unicode_blank::is_blank;

// `tx_read_only` is the name MariaDB and MySQL before 8.0 also take.
const READ_ONLY_SETTINGS: [&str; 3] = ["transaction_read_only", "default_transaction_read_only", "tx_read_only"];

// A statement that makes a transaction or the session read-write, or sets or resets a read-only setting. A function
// it calls is out of sight, so a session read-only only by its default can still be turned off.
pub fn turns_read_write(sql: &str, grammar: SqlGrammar) -> bool {
    if !grammar.is_sql() {
        return false;
    }
    if turns_as_sent(sql, grammar, CLIENT_SPLITS) {
        return true;
    }
    let letters = matches!(grammar, SqlGrammar::PostgreSql | SqlGrammar::Sqlite);
    !letters && sql.contains(may_be_space) && turns_as_sent(&sql.replace(may_be_space, " "), grammar, CLIENT_SPLITS)
}

fn turns_as_sent(sql: &str, grammar: SqlGrammar, splits: u8) -> bool {
    turns_every_way(sql, grammar)
        || (splits > 0
            && ScriptPlan::client_pieces(sql, grammar)
                .into_iter()
                .any(|piece| turns_as_sent(piece, grammar, splits - 1)))
}

fn turns_every_way(sql: &str, grammar: SqlGrammar) -> bool {
    let Some(mut plans) = ScriptPlan::server_readings(sql, grammar) else {
        return true;
    };
    plans.any(|plan| {
        plan.statements().iter().any(|statement| {
            let tokens: Vec<ScriptToken> = plan.tokens(statement.range.clone()).collect();
            let code = code_of(sql, &tokens);
            let blanks_inside = code
                .iter()
                .any(|token| token.kind == Kind::Word && token.text.contains(is_blank));
            turns(&code, grammar) || (blanks_inside && turns(&split_at_blanks(&code), grammar))
        })
    })
}

fn turns(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    code.split(|token| token.kind == Kind::End)
        .filter(|part| !part.is_empty())
        .any(|part| {
            let Some(opener) = part.first().filter(|first| first.kind == Kind::Word) else {
                return false;
            };
            let sets = is(opener.text, &["SET", "RESET"]);
            (is(opener.text, &["SET", "BEGIN", "START"]) && says_read_write(part))
                || (sets && part.iter().any(names_read_only_setting))
                || (sets && decodes_unicode_names(grammar) && (0..part.len()).any(|at| spelled_in_escapes(part, at)))
        })
}

fn says_read_write(part: &[Code<'_>]) -> bool {
    part.windows(2)
        .any(|pair| pair[0].is_word(&["READ"]) && pair[1].is_word(&["WRITE"]))
}

// MySQL names a variable `@@session.transaction_read_only`, `SESSION transaction_read_only` or in backquotes.
fn names_read_only_setting(token: &Code<'_>) -> bool {
    if !matches!(token.kind, Kind::Word | Kind::Quoted) {
        return false;
    }
    let name = token.text.rsplit('.').next().unwrap_or(token.text);
    is(name.trim_start_matches('@'), &READ_ONLY_SETTINGS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statements_that_turn_a_postgresql_transaction_or_session_read_write() {
        for sql in [
            "SET TRANSACTION READ WRITE",
            "set transaction isolation level serializable, read write",
            "SET SESSION TRANSACTION READ WRITE",
            "SET LOCAL transaction_read_only = off",
            "SET transaction_read_only TO 'false'",
            "SET \"transaction_read_only\" = 0",
            "RESET transaction_read_only",
            "SET default_transaction_read_only = off",
            "RESET default_transaction_read_only",
            "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
            "BEGIN READ WRITE",
            "BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE",
            "begin transaction read write",
            "START TRANSACTION READ WRITE",
            "START TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ WRITE",
            "SET U&\"transaction\\005fread_only\" = off",
            "SET /* why */ TRANSACTION READ -- \n WRITE",
            "SELECT 1; SET TRANSACTION READ WRITE",
        ] {
            assert!(turns_read_write(sql, SqlGrammar::PostgreSql), "{sql}");
        }
    }

    #[test]
    fn statements_that_turn_a_mysql_transaction_or_session_read_write() {
        for sql in [
            "START TRANSACTION READ WRITE",
            "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ WRITE",
            "SET TRANSACTION READ WRITE",
            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED, READ WRITE",
            "SET GLOBAL TRANSACTION READ WRITE",
            "SET SESSION transaction_read_only = 0",
            "SET @@transaction_read_only = OFF",
            "SET @@session.transaction_read_only = DEFAULT",
            "SET @@LOCAL.tx_read_only = 0",
            "SET @x = 1, `transaction_read_only` = OFF",
            "SET PERSIST transaction_read_only = 0",
            "SET STATEMENT transaction_read_only = 0 FOR SELECT 1",
            "/*!50000 SET SESSION TRANSACTION READ WRITE */",
            "SET\u{3000}TRANSACTION READ WRITE",
        ] {
            assert!(turns_read_write(sql, SqlGrammar::MySql), "{sql}");
        }
    }

    #[test]
    fn isolation_levels_reads_and_read_only_modes_are_not_read_write() {
        for grammar in [SqlGrammar::PostgreSql, SqlGrammar::MySql] {
            for sql in [
                "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE",
                "SET TRANSACTION READ ONLY",
                "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
                "BEGIN",
                "BEGIN ISOLATION LEVEL REPEATABLE READ",
                "START TRANSACTION READ ONLY",
                "START TRANSACTION WITH CONSISTENT SNAPSHOT",
                "COMMIT",
                "SELECT 'SET TRANSACTION READ WRITE'",
                "SELECT read, write FROM t",
                "SELECT current_setting('transaction_read_only')",
                "SET search_path = public",
                "SHOW transaction_read_only",
            ] {
                assert!(!turns_read_write(sql, grammar), "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn engines_without_these_statements_answer_no() {
        assert!(!turns_read_write("SET TRANSACTION READ WRITE", SqlGrammar::Redis));
        assert!(!turns_read_write("db.t.find()", SqlGrammar::Mongo));
    }
}
