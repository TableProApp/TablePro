//! An editor script goes one statement per round trip. Sent whole, the
//! server starts each next statement once the last one's result is
//! written, read or not, so a KILL that misses lets the rest run.

use std::ops::Range;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

/// Split where the mysql client splits: at each `;`, or at the delimiter
/// a DELIMITER line sets.
pub(crate) fn texts(sql: &str) -> Vec<&str> {
    let plan = ScriptPlan::build(sql, SqlGrammar::MySql, LexicalSettings::default_for(SqlGrammar::MySql));
    // A string or comment that never closes: the server reports it.
    if !plan.diagnostics().is_empty() {
        return vec![sql];
    }
    let tokens: Vec<ScriptToken> = plan.tokens(0..sql.len()).collect();
    let units = units(sql, &tokens);
    let directives = tokens.iter().any(|token| token.kind == ScriptTokenKind::Directive);
    // One statement goes as written: the client's view of where it ends
    // can differ from the server's, as under NO_BACKSLASH_ESCAPES.
    if !directives && (units.len() <= 1 || whole_by_server(sql, &tokens, &units)) {
        return vec![sql];
    }
    units.into_iter().filter_map(|unit| sql.get(unit)).collect()
}

/// The text between each two terminators, less the whitespace and plain
/// comments at its edges. The server runs what a `/*!` comment holds, so
/// such a comment is code, even standing alone.
fn units(sql: &str, tokens: &[ScriptToken]) -> Vec<Range<usize>> {
    let mut units = Vec::new();
    let mut code: Option<Range<usize>> = None;
    for token in tokens {
        if matches!(token.kind, ScriptTokenKind::Semicolon | ScriptTokenKind::Directive) {
            units.extend(code.take());
        } else if !token.kind.is_trivia() || executable(sql, token) {
            code = Some(code.map_or(token.range.clone(), |code| code.start..token.range.end));
        }
    }
    units.extend(code);
    units
}

fn executable(sql: &str, token: &ScriptToken) -> bool {
    token.kind == ScriptTokenKind::BlockComment
        && sql
            .get(token.range.clone())
            .is_some_and(|text| text.starts_with("/*!") || text.starts_with("/*M!"))
}

/// The client's split holds only for statements it reads as the server
/// does. A statement it does not know may have a body, which only the
/// server's grammar can end, and the session's sql_mode decides how some
/// text reads: a backslash in a string, `[name]` under MariaDB's MSSQL
/// mode, `$$` quotes on MySQL 8.4. A `/*!` comment may split on its own.
fn whole_by_server(sql: &str, tokens: &[ScriptToken], units: &[Range<usize>]) -> bool {
    let read_by_the_server = |token: &ScriptToken| {
        let text = sql.get(token.range.clone()).unwrap_or_default();
        match token.kind {
            ScriptTokenKind::BlockComment => executable(sql, token),
            ScriptTokenKind::StringLiteral => text.contains('\\'),
            ScriptTokenKind::Word => text.contains('$'),
            ScriptTokenKind::Punct => !PLAIN_PUNCTUATION.contains(text),
            _ => false,
        }
    };
    tokens.iter().any(read_by_the_server)
        || units.iter().any(|unit| {
            let first = tokens.partition_point(|token| token.range.end <= unit.start);
            let last = tokens.partition_point(|token| token.range.start < unit.end);
            !plain(sql, tokens.get(first..last).unwrap_or_default())
        })
}

const PLAIN_PUNCTUATION: &str = ",.=<>!+-*/%&|^~:@?";

/// The words that start a statement with no body of its own.
const PLAIN_STARTS: [&str; 54] = [
    "ANALYZE",
    "BACKUP",
    "BINLOG",
    "CACHE",
    "CALL",
    "CHANGE",
    "CHECK",
    "CHECKSUM",
    "CLONE",
    "COMMIT",
    "DEALLOCATE",
    "DELETE",
    "DESC",
    "DESCRIBE",
    "DO",
    "DROP",
    "EXECUTE",
    "EXPLAIN",
    "FLUSH",
    "GRANT",
    "HANDLER",
    "HELP",
    "IMPORT",
    "INSERT",
    "INSTALL",
    "KILL",
    "LOAD",
    "LOCK",
    "OPTIMIZE",
    "PREPARE",
    "PURGE",
    "RELEASE",
    "RENAME",
    "REPAIR",
    "REPLACE",
    "RESET",
    "RESTART",
    "REVOKE",
    "ROLLBACK",
    "SAVEPOINT",
    "SELECT",
    "SET",
    "SHOW",
    "SHUTDOWN",
    "START",
    "TABLE",
    "TRUNCATE",
    "UNINSTALL",
    "UNLOCK",
    "UPDATE",
    "USE",
    "VALUES",
    "WITH",
    "XA",
];

/// Objects whose definition never holds a `;`.
const PLAIN_OBJECTS: [&str; 18] = [
    "TABLE",
    "TEMPORARY",
    "VIEW",
    "INDEX",
    "UNIQUE",
    "FULLTEXT",
    "SPATIAL",
    "DATABASE",
    "SCHEMA",
    "USER",
    "ROLE",
    "SERVER",
    "SEQUENCE",
    "TABLESPACE",
    "LOGFILE",
    "RESOURCE",
    "UNDO",
    "INSTANCE",
];

fn plain(sql: &str, tokens: &[ScriptToken]) -> bool {
    let text = |token: &ScriptToken| sql.get(token.range.clone()).unwrap_or_default();
    let mut rest = tokens;
    let Some(first) = next_significant(&mut rest) else {
        return true;
    };
    if first.kind != ScriptTokenKind::Word {
        return false;
    }
    let word = text(first);
    if is(word, &["CREATE", "ALTER"]) {
        return !creates_program(sql, rest);
    }
    // BEGIN and BEGIN WORK start a transaction; anything else after it
    // is a block: BEGIN NOT ATOMIC, or sql_mode=ORACLE.
    if is(word, &["BEGIN"]) {
        return next_significant(&mut rest)
            .is_none_or(|token| token.kind == ScriptTokenKind::Word && is(text(token), &["WORK"]));
    }
    is(word, &PLAIN_STARTS)
}

/// Whether the header after CREATE or ALTER may name a stored program,
/// read past `OR REPLACE`, `AGGREGATE`, `DEFINER = user`, `SQL SECURITY`
/// and `ALGORITHM`. Anything but a plain object counts, since sending a
/// plain statement whole costs less than cutting a body apart.
fn creates_program(sql: &str, tokens: &[ScriptToken]) -> bool {
    let text = |token: &ScriptToken| sql.get(token.range.clone()).unwrap_or_default();
    let mut rest = tokens;
    loop {
        let Some(token) = next_significant(&mut rest) else {
            return false;
        };
        if token.kind != ScriptTokenKind::Word {
            return true;
        }
        let word = text(token);
        match word.to_ascii_uppercase().as_str() {
            "OR" | "REPLACE" | "AGGREGATE" => {}
            "SQL" | "ALGORITHM" => {
                next_significant(&mut rest);
                next_significant(&mut rest);
            }
            "DEFINER" => {
                next_significant(&mut rest);
                skip_user(sql, &mut rest);
            }
            _ => return !is(word, &PLAIN_OBJECTS),
        }
    }
}

/// Past `CURRENT_USER`, `CURRENT_USER()`, `name`, or `name@host` with the
/// host written as one run of tokens (`127.0.0.1`).
fn skip_user(sql: &str, tokens: &mut &[ScriptToken]) {
    let is_punct = |token: Option<&ScriptToken>, punct: &str| {
        token.is_some_and(|token| sql.get(token.range.clone()) == Some(punct))
    };
    let Some(name) = next_significant(tokens) else {
        return;
    };
    let peek = |tokens: &[ScriptToken]| tokens.iter().find(|token| !token.kind.is_trivia()).cloned();
    if sql
        .get(name.range.clone())
        .is_some_and(|text| text.eq_ignore_ascii_case("CURRENT_USER"))
    {
        if peek(tokens).is_some_and(|token| token.kind == ScriptTokenKind::OpenParen) {
            next_significant(tokens);
            next_significant(tokens);
        }
        return;
    }
    if is_punct(peek(tokens).as_ref(), "@") {
        next_significant(tokens);
        next_significant(tokens);
        let joined = tokens
            .iter()
            .position(|token| token.kind.is_trivia())
            .unwrap_or(tokens.len());
        *tokens = tokens.get(joined..).unwrap_or_default();
    }
}

fn next_significant<'a>(tokens: &mut &'a [ScriptToken]) -> Option<&'a ScriptToken> {
    let at = tokens.iter().position(|token| !token.kind.is_trivia())?;
    let token = tokens.get(at)?;
    *tokens = tokens.get(at + 1..).unwrap_or_default();
    Some(token)
}

fn is(text: &str, words: &[&str]) -> bool {
    words.iter().any(|word| text.eq_ignore_ascii_case(word))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_script_goes_one_statement_at_a_time() {
        assert_eq!(texts("SELECT 1; SELECT 2"), ["SELECT 1", "SELECT 2"]);
        assert_eq!(
            texts("BEGIN;\nINSERT INTO t VALUES (';');\n-- done\nCOMMIT;"),
            ["BEGIN", "INSERT INTO t VALUES (';')", "COMMIT"]
        );
        assert_eq!(texts("BEGIN WORK; SELECT 1"), ["BEGIN WORK", "SELECT 1"]);
        assert_eq!(texts("XA BEGIN 'x'; SELECT 1"), ["XA BEGIN 'x'", "SELECT 1"]);
        assert_eq!(
            texts("SET @a := -1; SELECT @@session.sql_mode, j->>'$.x' FROM t WHERE a <> 2 OR b IS NULL"),
            [
                "SET @a := -1",
                "SELECT @@session.sql_mode, j->>'$.x' FROM t WHERE a <> 2 OR b IS NULL"
            ]
        );
        assert_eq!(
            texts("CREATE TABLE t (id int); DROP PROCEDURE p"),
            ["CREATE TABLE t (id int)", "DROP PROCEDURE p"]
        );
        assert_eq!(
            texts(
                "CREATE TABLE x (event int); CREATE DEFINER = admin@localhost SQL SECURITY INVOKER VIEW v AS SELECT 1"
            ),
            [
                "CREATE TABLE x (event int)",
                "CREATE DEFINER = admin@localhost SQL SECURITY INVOKER VIEW v AS SELECT 1"
            ]
        );
    }

    #[test]
    fn one_statement_goes_as_written() {
        for script in [
            "-- note\n/* plain */ ;;",
            "SELECT 1;\n-- trailing",
            "SELECT 'a\\'; SELECT 'b -- ';",
            "/*M!100100 SET @a = 1 */",
        ] {
            assert_eq!(texts(script), [script], "{script}");
        }
    }

    #[test]
    fn delimiter_scripts_split_where_the_client_would() {
        let script = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nCALL p();";

        assert_eq!(
            texts(script),
            ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()"]
        );
    }

    /// mysqldump writes a trigger as a run of `/*!` comments, which the
    /// server runs.
    #[test]
    fn executable_comments_are_sent() {
        let dump = "DELIMITER ;;\n/*!50003 CREATE*/ /*!50003 TRIGGER t1 BEFORE INSERT ON t FOR EACH ROW \
                    BEGIN SET NEW.a = 1; END */;;\nDELIMITER ;\n/*!40101 SET NAMES utf8mb4 */;";

        assert_eq!(
            texts(dump),
            [
                "/*!50003 CREATE*/ /*!50003 TRIGGER t1 BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; END */",
                "/*!40101 SET NAMES utf8mb4 */"
            ]
        );
    }

    #[test]
    fn a_body_only_the_server_can_end_goes_whole() {
        let whole = [
            "CREATE TABLE tt (a int); CREATE TRIGGER b BEFORE INSERT ON tt FOR EACH ROW BEGIN SET NEW.a = 1; END",
            "CREATE DEFINER = admin@localhost PROCEDURE p() IF 1 THEN SELECT 1; END IF",
            "ALTER EVENT e DO BEGIN DELETE FROM t; END",
            "CREATE OR REPLACE DEFINER = 'a'@'%' AGGREGATE FUNCTION f(x int) RETURNS int BEGIN RETURN 1; END",
            "CREATE DEFINER = CURRENT_USER() TRIGGER g BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.id = 1; END",
            "CREATE DEFINER=root@127.0.0.1 PROCEDURE p() BEGIN SELECT 1; END",
            "CREATE DEFINER = CURRENT_USER( ) PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
            "CREATE DEFINER = 'a' @ 'b' EVENT e ON SCHEDULE EVERY 1 DAY DO BEGIN DELETE FROM t; END",
            "CREATE DEFINER = user@localhost PROCEDURE p() BEGIN SELECT 1; END",
            "/*!40101 SET NAMES utf8mb4 */; SELECT 1",
            "BEGIN NOT ATOMIC SELECT 1; END",
            "IF 1 THEN SELECT 1; END IF",
            "WHILE @a < 3 DO SET @a = @a + 1; END WHILE",
            "l1: LOOP LEAVE l1; END LOOP",
            "`l1`: BEGIN NOT ATOMIC SELECT 1; END",
            "SELECT 1 /*! ; DELETE FROM t */; SELECT 2",
            "SELECT 'a\\'; DELETE FROM t; SELECT \\''; SELECT 1",
            "SELECT 1 AS [a;b]; SELECT 2",
            "SELECT $$a;b$$; SELECT 1",
            "SELECT {d '2020-01-01'}; SELECT 1",
            "BEGIN \"p\"(); END",
            "(SELECT 1); DELETE FROM t",
        ];

        for script in whole {
            assert_eq!(texts(script), [script], "{script}");
        }
    }

    #[test]
    fn unterminated_text_goes_whole() {
        assert_eq!(texts("SELECT 1; SELECT 'open"), ["SELECT 1; SELECT 'open"]);
    }
}
