use std::collections::HashMap;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{ScriptPlan, ScriptToken, ScriptTokenKind};

/// What running a piece of SQL can do, from its own words. Ordered, so
/// the strictest of several statements is their maximum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum StatementAccess {
    Read,
    Write,
    /// DROP, TRUNCATE, or a DELETE or UPDATE with no WHERE.
    Destructive,
}

/// The words a statement that only reads may open with. EXPLAIN and
/// DESCRIBE count because the write words below still catch
/// `EXPLAIN ANALYZE DELETE`, which runs the delete.
const READ_VERBS: [&str; 8] = [
    "SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN", "DESCRIBE", "DESC",
];

/// Words that make a statement a write wherever they stand: a CTE that
/// deletes, `SELECT … INTO`, `FOR UPDATE`. `REPLACE` and `COPY` are left
/// out because they are also function and column names in a read.
const WRITE_WORDS: [&str; 15] = [
    "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "INTO", "CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE",
    "EXEC", "EXECUTE", "CALL",
];

/// SQL Server needs no `;` between statements, so a batch that opens
/// with SELECT can go on to any of these. They are the T-SQL statements
/// that change data, state or the server, beyond the words above.
const TSQL_WRITE_WORDS: [&str; 26] = [
    "DENY",
    "BEGIN",
    "COMMIT",
    "ROLLBACK",
    "SAVE",
    "BACKUP",
    "RESTORE",
    "DBCC",
    "KILL",
    "SHUTDOWN",
    "RECONFIGURE",
    "CHECKPOINT",
    "BULK",
    "UPDATETEXT",
    "WRITETEXT",
    "RECEIVE",
    "SEND",
    "MOVE",
    "SETUSER",
    "ENABLE",
    "DISABLE",
    "ADD",
    "RENAME",
    "OPENQUERY",
    "OPENROWSET",
    "OPENDATASOURCE",
];

/// SQLite pragmas that only report. Any other pragma, and any pragma
/// given a value, can change the database or the connection.
const REPORTING_PRAGMAS: [&str; 16] = [
    "TABLE_INFO",
    "TABLE_XINFO",
    "TABLE_LIST",
    "INDEX_INFO",
    "INDEX_XINFO",
    "INDEX_LIST",
    "FOREIGN_KEY_LIST",
    "FOREIGN_KEY_CHECK",
    "INTEGRITY_CHECK",
    "QUICK_CHECK",
    "FUNCTION_LIST",
    "PRAGMA_LIST",
    "MODULE_LIST",
    "COLLATION_LIST",
    "DATABASE_LIST",
    "COMPILE_OPTIONS",
];

/// Words that begin a statement, so one that follows another statement's
/// words without a clause word between starts a new statement. WITH is
/// left out: SQL Server writes a table hint as `WITH (NOLOCK)`.
const STATEMENT_VERBS: [&str; 10] = [
    "DELETE", "UPDATE", "DROP", "TRUNCATE", "SELECT", "INSERT", "MERGE", "EXEC", "EXECUTE", "ALTER",
];

/// Built-in functions that change state from inside a SELECT: sequences,
/// settings, other sessions, large objects, replication. A function the
/// user wrote is beyond what the words show; on PostgreSQL and MySQL a
/// Read-Only connection's read-only transaction still refuses its write.
const MUTATING_FUNCTIONS: [&str; 22] = [
    "SETVAL",
    "NEXTVAL",
    "SET_CONFIG",
    "PG_TERMINATE_BACKEND",
    "PG_CANCEL_BACKEND",
    "PG_RELOAD_CONF",
    "PG_ROTATE_LOGFILE",
    "PG_SWITCH_WAL",
    "PG_PROMOTE",
    "PG_CREATE_RESTORE_POINT",
    "PG_CREATE_PHYSICAL_REPLICATION_SLOT",
    "PG_CREATE_LOGICAL_REPLICATION_SLOT",
    "PG_DROP_REPLICATION_SLOT",
    "PG_STAT_RESET",
    "LO_CREATE",
    "LO_IMPORT",
    "LO_EXPORT",
    "LO_UNLINK",
    "LO_PUT",
    "LO_FROM_BYTEA",
    "DBLINK_EXEC",
    "LOAD_EXTENSION",
];

/// Statement verbs that MySQL also has as functions: `TRUNCATE(x, 2)`
/// rounds and `INSERT(s, 1, 2, 'x')` splices, both inside a read.
const ALSO_FUNCTIONS: [&str; 2] = ["TRUNCATE", "INSERT"];

/// What a CREATE or ALTER defines when the rest of it is a body that
/// runs later, not now.
const ROUTINES: [&str; 6] = ["PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "RULE", "EVENT"];

/// Words between CREATE or ALTER and the kind of thing declared.
const DECLARATION_MODIFIERS: [&str; 10] = [
    "OR",
    "REPLACE",
    "ALTER",
    "DEFINER",
    "CONSTRAINT",
    "TEMP",
    "TEMPORARY",
    "AGGREGATE",
    "EDITIONABLE",
    "NONEDITIONABLE",
];

/// Words after which DELETE, UPDATE, DROP or TRUNCATE are part of the
/// statement rather than the start of another: `ON DELETE CASCADE`,
/// `FOR UPDATE`, `ON CONFLICT DO UPDATE`, `GRANT DELETE`, a trigger's
/// `AFTER UPDATE OF`.
const CLAUSE_WORDS: [&str; 15] = [
    "ON", "THEN", "FOR", "OF", "AFTER", "BEFORE", "INSTEAD", "DO", "KEY", "GRANT", "REVOKE", "DENY", "AND", "OR", "NOT",
];

/// The strictest access among the statements of `sql`.
///
/// A statement reads only when its words show it does, so anything
/// unrecognized counts as a write. The text is read every way a server
/// may read it and the strictest answer stands: where a string ends can
/// hang on a session setting the app cannot see, such as
/// `NO_BACKSLASH_ESCAPES`, and which MySQL executable comments run hangs
/// on the server's version. Each piece a `DELIMITER` line cuts it into is
/// read on its own too, since a client sends them apart.
pub fn statement_access(sql: &str, grammar: SqlGrammar) -> StatementAccess {
    if grammar == SqlGrammar::Redis {
        return crate::sql_syntax::redis::script_access(sql);
    }
    access_as_sent(sql, grammar, CLIENT_SPLITS)
}

/// How many times a script can be split by `DELIMITER` lines on its way:
/// once by the editor, once more by the driver.
pub(crate) const CLIENT_SPLITS: u8 = 2;

fn access_as_sent(sql: &str, grammar: SqlGrammar, splits: u8) -> StatementAccess {
    let whole = access_every_way(sql, grammar);
    if whole == StatementAccess::Destructive || splits == 0 {
        return whole;
    }
    ScriptPlan::client_pieces(sql, grammar)
        .into_iter()
        .map(|piece| access_as_sent(piece, grammar, splits - 1))
        .fold(whole, StatementAccess::max)
}

fn access_every_way(sql: &str, grammar: SqlGrammar) -> StatementAccess {
    let Some(plans) = ScriptPlan::server_readings(sql, grammar) else {
        return StatementAccess::Destructive;
    };
    let mut strictest = None;
    for plan in plans {
        let access = access_in(sql, grammar, &plan);
        if access == StatementAccess::Destructive {
            return access;
        }
        strictest = strictest.max(Some(access));
    }
    strictest.unwrap_or(StatementAccess::Write)
}

fn access_in(sql: &str, grammar: SqlGrammar, plan: &ScriptPlan) -> StatementAccess {
    let unreadable = match plan.diagnostics().is_empty() {
        true => StatementAccess::Read,
        false => StatementAccess::Write,
    };
    plan.statements()
        .iter()
        .map(|statement| {
            let tokens: Vec<ScriptToken> = plan.tokens(statement.range.clone()).collect();
            access_of(sql, grammar, &tokens)
        })
        .fold(unreadable, StatementAccess::max)
}

fn access_of(sql: &str, grammar: SqlGrammar, tokens: &[ScriptToken]) -> StatementAccess {
    let code = code_of(sql, tokens);
    if code.iter().all(|token| token.kind == Kind::End) || plans_only(&code, grammar) {
        return StatementAccess::Read;
    }
    if destructive(&code, grammar) {
        return StatementAccess::Destructive;
    }
    // A SQL Server batch is one statement here, so each part between
    // `;` has to read on its own.
    let reads = code
        .split(|token| token.kind == Kind::End)
        .filter(|part| !part.is_empty())
        .all(|part| opens_as_read(part, grammar) && !writes(part, grammar));
    match reads {
        true => StatementAccess::Read,
        false => StatementAccess::Write,
    }
}

/// EXPLAIN, and MySQL's DESCRIBE of a statement, without ANALYZE shows
/// a plan and runs nothing. SQL Server has no EXPLAIN, and its batch
/// could hold a statement after one.
fn plans_only(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    grammar != SqlGrammar::MsSql
        && code
            .first()
            .is_some_and(|first| first.is_word(&["EXPLAIN", "DESCRIBE", "DESC"]))
        && !code.iter().any(|token| token.is_word(&["ANALYZE", "ANALYSE"]))
        && code.iter().rev().skip(1).all(|token| token.kind != Kind::End)
}

/// Whether a word in `part` writes wherever it stands. Every SHOW only
/// reports, `SHOW CREATE TABLE` included.
fn writes(part: &[Code<'_>], grammar: SqlGrammar) -> bool {
    if part.first().is_some_and(|first| first.is_word(&["SHOW"])) {
        return false;
    }
    let follows = |index: usize, set: &[&str]| index > 0 && part[index - 1].is_word(set);
    part.iter().enumerate().any(|(index, token)| match token.kind {
        Kind::Word => {
            !is_call(part, index)
                && (is(token.text, &WRITE_WORDS)
                    || (grammar == SqlGrammar::MsSql && is(token.text, &TSQL_WRITE_WORDS))
                    || (is(token.text, &["SHARE"]) && follows(index, &["FOR", "KEY", "IN"]))
                    // `NEXT VALUE FOR` takes a number from a sequence.
                    || (is(token.text, &["VALUE"]) && follows(index, &["NEXT"]))
                    || calls_mutator(part, index))
        }
        Kind::Quoted => calls_mutator(part, index),
        _ => false,
    })
}

/// A call of a built-in that changes state, its name quoted or not.
fn calls_mutator(part: &[Code<'_>], index: usize) -> bool {
    is(part[index].text, &MUTATING_FUNCTIONS) && part.get(index + 1).is_some_and(|next| next.kind == Kind::Open)
}

/// A verb MySQL also has as a function, called as one.
fn is_call(code: &[Code<'_>], index: usize) -> bool {
    code[index].is_word(&ALSO_FUNCTIONS) && code.get(index + 1).is_some_and(|next| next.kind == Kind::Open)
}

fn opens_as_read(part: &[Code<'_>], grammar: SqlGrammar) -> bool {
    let Some(first) = part.first() else {
        return true;
    };
    match first.kind {
        Kind::Open => true,
        Kind::Word if is(first.text, &["PRAGMA"]) => grammar == SqlGrammar::Sqlite && reporting_pragma(part),
        Kind::Word => is(first.text, &READ_VERBS),
        _ => false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Word,
    Open,
    Close,
    Comma,
    Equals,
    /// A `;` outside parentheses, which ends a statement.
    End,
    /// A quoted name, its text without the quotes.
    Quoted,
    Other,
}

/// A significant token and the parenthesis depth it sits at. A close
/// sits at the depth of its open.
#[derive(Debug, Clone, Copy)]
struct Code<'a> {
    kind: Kind,
    text: &'a str,
    depth: usize,
}

impl Code<'_> {
    fn is_word(&self, set: &[&str]) -> bool {
        self.kind == Kind::Word && is(self.text, set)
    }
}

fn code_of<'a>(sql: &'a str, tokens: &[ScriptToken]) -> Vec<Code<'a>> {
    let mut depth = 0usize;
    tokens
        .iter()
        .filter(|token| {
            !token.kind.is_trivia()
                && !matches!(
                    token.kind,
                    ScriptTokenKind::Directive | ScriptTokenKind::ExecutableMarker
                )
        })
        .map(|token| {
            let text = sql.get(token.range.clone()).unwrap_or_default();
            let at = depth;
            let kind = match token.kind {
                ScriptTokenKind::OpenParen => {
                    depth += 1;
                    Kind::Open
                }
                ScriptTokenKind::CloseParen => {
                    depth = depth.saturating_sub(1);
                    Kind::Close
                }
                ScriptTokenKind::Semicolon if depth == 0 => Kind::End,
                ScriptTokenKind::Word => Kind::Word,
                ScriptTokenKind::QuotedIdentifier => Kind::Quoted,
                ScriptTokenKind::Punct if text == "," => Kind::Comma,
                ScriptTokenKind::Punct if text == "=" => Kind::Equals,
                _ => Kind::Other,
            };
            let depth = match kind {
                Kind::Close => depth,
                _ => at,
            };
            let text = match kind {
                Kind::Quoted => text.get(1..text.len().saturating_sub(1)).unwrap_or_default(),
                _ => text,
            };
            Code { kind, text, depth }
        })
        .collect()
}

/// Whether some statement in `code` drops, empties, or changes every row
/// of a table. Once a routine or trigger is being defined, the rest is
/// its body, which does not run now.
fn destructive(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    for statement in code.split(|token| token.kind == Kind::End) {
        if defines_routine(statement) {
            return false;
        }
        if statement_destroys(statement, grammar) {
            return true;
        }
    }
    false
}

/// `CREATE [OR REPLACE | OR ALTER] [DEFINER = …] [CONSTRAINT] TRIGGER`
/// and the like: the first word after the modifiers names what is
/// declared, and a table called `event` is still a table.
fn defines_routine(statement: &[Code<'_>]) -> bool {
    let mut words = statement
        .iter()
        .filter(|token| token.kind == Kind::Word && token.depth == 0);
    if !words.next().is_some_and(|first| first.is_word(&["CREATE", "ALTER"])) {
        return false;
    }
    words
        .find(|word| !word.is_word(&DECLARATION_MODIFIERS))
        .is_some_and(|kind| kind.is_word(&ROUTINES))
}

/// A new statement starts at a statement verb unless a clause word or a
/// list comma leads into it, which finds the second statement of a SQL
/// Server batch written without `;`; one in parentheses is a
/// data-modifying CTE.
fn statement_destroys(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    let starts = statement_starts(code);
    // Each start's segment runs to the next start at its depth, found in
    // one pass from the end.
    let mut next_at_depth: HashMap<usize, usize> = HashMap::new();
    let mut ends = vec![code.len(); starts.len()];
    for (nth, &start) in starts.iter().enumerate().rev() {
        let depth = code[start].depth;
        if let Some(&next) = next_at_depth.get(&depth) {
            ends[nth] = next;
        }
        next_at_depth.insert(depth, start);
    }
    starts
        .iter()
        .zip(ends)
        .any(|(&start, end)| segment_destroys(&code[start..end], grammar))
}

fn statement_starts(code: &[Code<'_>]) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut lead: Option<&str> = None;
    for (index, token) in code.iter().enumerate() {
        let opens = match index.checked_sub(1).map(|before| &code[before]) {
            _ if is_call(code, index) => false,
            None => token.kind == Kind::Word,
            Some(before) if token.is_word(&["DELETE", "UPDATE"]) && before.kind == Kind::Open => true,
            Some(before) if token.depth == 0 && token.is_word(&STATEMENT_VERBS) => {
                let led_in = before.is_word(&CLAUSE_WORDS) || before.kind == Kind::Comma;
                let alters = lead.is_some_and(|lead| is(lead, &["ALTER"])) && token.is_word(&["DROP", "ALTER"]);
                !led_in && !alters
            }
            Some(_) => false,
        };
        if opens {
            starts.push(index);
            if token.depth == 0 {
                lead = Some(token.text);
            }
        }
    }
    starts
}

/// The statement that starts at `code[0]` and runs to the end of `code`
/// or the parenthesis that closes it.
fn segment_destroys(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    let Some(lead) = code.first() else {
        return false;
    };
    if lead.is_word(&["DROP", "TRUNCATE"]) {
        return true;
    }
    if !lead.is_word(&["DELETE", "UPDATE"]) {
        return false;
    }
    // T-SQL's UPDATE STATISTICS refreshes the optimizer's numbers.
    if grammar == SqlGrammar::MsSql && code.get(1).is_some_and(|next| next.is_word(&["STATISTICS"])) {
        return false;
    }
    let depth = lead.depth;
    !code
        .iter()
        .skip(1)
        .take_while(|token| !(token.kind == Kind::Close && token.depth < depth))
        .any(|token| token.depth == depth && token.is_word(&["WHERE"]))
}

/// `PRAGMA [schema.]name[(argument)]` for a pragma that only reports.
fn reporting_pragma(code: &[Code<'_>]) -> bool {
    let name = code
        .iter()
        .skip(1)
        .take_while(|token| token.kind != Kind::Open)
        .filter(|token| token.kind == Kind::Word)
        .last();
    let assigns = code.iter().any(|token| token.kind == Kind::Equals);
    !assigns && name.is_some_and(|name| is(name.text, &REPORTING_PRAGMAS))
}

fn is(word: &str, set: &[&str]) -> bool {
    set.iter().any(|known| word.eq_ignore_ascii_case(known))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn access(sql: &str, grammar: SqlGrammar) -> StatementAccess {
        statement_access(sql, grammar)
    }

    #[test]
    fn reads_are_reads_in_every_grammar() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "SELECT * FROM orders",
                "select id from orders where note = 'DELETE FROM orders'",
                "-- DROP TABLE orders\nSELECT 1",
                "/* UPDATE orders */ SELECT 1",
                "(SELECT 1) UNION (SELECT 2)",
                "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent",
                "EXPLAIN SELECT * FROM orders",
                "SELECT replace(name, 'a', 'b') FROM orders",
                "",
                "-- only a note",
            ] {
                assert_eq!(access(sql, grammar), StatementAccess::Read, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn engine_specific_reads() {
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "TABLE orders"),
            (SqlGrammar::PostgreSql, "VALUES (1), (2)"),
            (SqlGrammar::PostgreSql, "SHOW search_path"),
            (SqlGrammar::PostgreSql, "SELECT $$DELETE FROM t$$"),
            (SqlGrammar::MySql, "SHOW TABLES"),
            (SqlGrammar::MySql, "DESCRIBE orders"),
            (SqlGrammar::MySql, "SELECT `update` FROM orders"),
            (SqlGrammar::MySql, "SELECT 1 /*+ MAX_EXECUTION_TIME(1000) */"),
            (SqlGrammar::Sqlite, "PRAGMA table_info(orders)"),
            (SqlGrammar::Sqlite, "PRAGMA main.index_list('orders')"),
            (SqlGrammar::MsSql, "SELECT [delete] FROM orders"),
            (SqlGrammar::MsSql, "SELECT 1\nSELECT 2"),
            (SqlGrammar::MsSql, "SELECT CASE WHEN a = 1 THEN 'x' END FROM t"),
            (
                SqlGrammar::ClickHouse,
                "SELECT * FROM events FORMAT JSONEachRow SETTINGS max_threads = 1",
            ),
            (SqlGrammar::ClickHouse, "DESC events"),
        ] {
            assert_eq!(access(sql, grammar), StatementAccess::Read, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn writes_are_writes_in_every_grammar() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "INSERT INTO orders VALUES (1)",
                "UPDATE orders SET total = 0 WHERE id = 1",
                "DELETE FROM orders WHERE id = 1",
                "CREATE TABLE t (id int)",
                "ALTER TABLE orders ADD note text",
                "SELECT * INTO copy FROM orders",
                "WITH gone AS (DELETE FROM orders WHERE id = 1 RETURNING *) SELECT * FROM gone",
                "SELECT * FROM orders FOR UPDATE",
                "EXPLAIN ANALYZE DELETE FROM orders WHERE id = 1",
                "SET search_path = public",
                "BEGIN",
                "COMMIT",
                "GRANT SELECT ON orders TO someone",
                "SELECT 1; INSERT INTO orders VALUES (1)",
                "SELECT 'unterminated",
                "something_new orders",
            ] {
                assert!(access(sql, grammar) >= StatementAccess::Write, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn engine_specific_writes() {
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "SELECT * FROM orders FOR SHARE"),
            (SqlGrammar::PostgreSql, "SELECT * FROM orders FOR KEY SHARE"),
            (SqlGrammar::PostgreSql, "COPY orders TO STDOUT"),
            (SqlGrammar::PostgreSql, "DO $$ BEGIN END $$"),
            (SqlGrammar::MySql, "SELECT * FROM orders LOCK IN SHARE MODE"),
            (SqlGrammar::MySql, "REPLACE INTO orders VALUES (1)"),
            (SqlGrammar::MySql, "SELECT 1 /*!50000 , (SELECT 1 FROM t FOR UPDATE) */"),
            (SqlGrammar::MySql, "USE shop"),
            (SqlGrammar::MySql, "SELECT 1;\n/*!50000 SET GLOBAL read_only = 0 */"),
            (SqlGrammar::Sqlite, "PRAGMA journal_mode = WAL"),
            (SqlGrammar::Sqlite, "PRAGMA user_version"),
            (SqlGrammar::Sqlite, "PRAGMA optimize"),
            (SqlGrammar::MsSql, "SELECT 1\nEXEC sp_who"),
            (SqlGrammar::MsSql, "SELECT 1 BACKUP DATABASE shop TO DISK = 'x'"),
            (SqlGrammar::MsSql, "SELECT * FROM OPENQUERY(remote, 'DELETE FROM t')"),
            (SqlGrammar::MsSql, "SELECT 1\nDISABLE TRIGGER ALL ON dbo.orders"),
            (SqlGrammar::MsSql, "SELECT 1\nENABLE TRIGGER ALL ON dbo.orders"),
            (SqlGrammar::ClickHouse, "OPTIMIZE TABLE events FINAL"),
            (SqlGrammar::ClickHouse, "SELECT 1 INTO OUTFILE 'x.csv'"),
        ] {
            assert!(access(sql, grammar) >= StatementAccess::Write, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn drops_truncates_and_unbounded_row_changes_are_destructive() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "DROP TABLE orders",
                "drop view if exists recent",
                "TRUNCATE TABLE orders",
                "DELETE FROM orders",
                "UPDATE orders SET total = 0",
                "UPDATE orders SET total = (SELECT max(total) FROM orders WHERE id = 1)",
                "WITH x AS (SELECT 1) DELETE FROM orders",
                "SELECT 1; DROP TABLE orders",
                "/* note */ DELETE FROM orders",
            ] {
                assert_eq!(access(sql, grammar), StatementAccess::Destructive, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn bounded_row_changes_and_clauses_are_not_destructive() {
        for grammar in SqlGrammar::SQL {
            for sql in [
                "DELETE FROM orders WHERE id = 1",
                "UPDATE orders SET total = 0 WHERE id = 1",
                "ALTER TABLE orders DROP COLUMN note",
                "CREATE TABLE lines (order_id int REFERENCES orders ON DELETE CASCADE)",
                "INSERT INTO orders VALUES (1) ON CONFLICT (id) DO UPDATE SET total = 0",
                "SELECT * FROM orders FOR UPDATE",
                "GRANT SELECT, UPDATE, DELETE ON orders TO someone",
                "CREATE TRIGGER t AFTER UPDATE OF total ON orders FOR EACH ROW EXECUTE FUNCTION f()",
                "SELECT 'DROP TABLE orders'",
            ] {
                assert_ne!(access(sql, grammar), StatementAccess::Destructive, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn a_sql_server_batch_without_semicolons_is_read_statement_by_statement() {
        for sql in [
            "SELECT 1\nDROP TABLE orders",
            "UPDATE orders SET total = 0 WHERE id = 1\nDELETE FROM lines",
            "INSERT INTO log VALUES (1)\nTRUNCATE TABLE orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Destructive, "{sql}");
        }
        assert_eq!(
            access("UPDATE STATISTICS orders", SqlGrammar::MsSql),
            StatementAccess::Write
        );
    }

    #[test]
    fn a_sql_server_batch_is_split_at_its_semicolons_too() {
        for sql in [
            "CREATE TABLE scratch (id int); DROP TABLE orders;",
            "DELETE FROM orders; SELECT * FROM audit WHERE id = 1;",
            "DELETE FROM orders SELECT * FROM audit WHERE id = 1",
            "UPDATE orders WITH (ROWLOCK) SET total = 0",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Destructive, "{sql}");
        }
        assert_eq!(
            access("DELETE FROM orders WITH (ROWLOCK) WHERE id = 1", SqlGrammar::MsSql),
            StatementAccess::Write
        );
        assert_eq!(
            access("SELECT 1; SET NOCOUNT ON", SqlGrammar::MsSql),
            StatementAccess::Write
        );
        assert_eq!(access("SELECT 1; SELECT 2;", SqlGrammar::MsSql), StatementAccess::Read);
    }

    #[test]
    fn verbs_mysql_also_has_as_functions_read_when_called() {
        for sql in [
            "SELECT TRUNCATE(total, 2) FROM orders",
            "SELECT INSERT(name, 1, 2, 'x') FROM orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Read, "{sql}");
        }
        assert_eq!(
            access("TRUNCATE TABLE orders", SqlGrammar::MySql),
            StatementAccess::Destructive
        );
    }

    #[test]
    fn a_select_that_calls_a_function_that_changes_state_writes() {
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "SELECT setval('orders_id_seq', 1, false)"),
            (SqlGrammar::PostgreSql, "SELECT nextval('orders_id_seq')"),
            (
                SqlGrammar::PostgreSql,
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity",
            ),
            (SqlGrammar::MsSql, "SELECT NEXT VALUE FOR dbo.order_ids"),
            (SqlGrammar::Sqlite, "SELECT load_extension('x')"),
        ] {
            assert_eq!(access(sql, grammar), StatementAccess::Write, "{grammar:?}: {sql}");
        }
        assert_eq!(
            access("SELECT currval('orders_id_seq')", SqlGrammar::PostgreSql),
            StatementAccess::Read
        );
    }

    #[test]
    fn a_carriage_return_ends_a_line_comment_where_the_engine_says_so() {
        let sql = "SELECT 1 -- x\r; COMMIT; DELETE FROM orders;\nSELECT 2";
        assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Destructive);
        assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Destructive);
    }

    #[test]
    fn explain_without_analyze_only_plans() {
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "EXPLAIN DELETE FROM orders"),
            (SqlGrammar::PostgreSql, "EXPLAIN (COSTS false) UPDATE orders SET id = 2"),
            (SqlGrammar::Sqlite, "EXPLAIN QUERY PLAN UPDATE orders SET id = 2"),
            (SqlGrammar::MySql, "EXPLAIN FORMAT=TREE DELETE FROM orders"),
        ] {
            assert_eq!(access(sql, grammar), StatementAccess::Read, "{grammar:?}: {sql}");
        }
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "EXPLAIN ANALYZE DELETE FROM orders"),
            (SqlGrammar::PostgreSql, "EXPLAIN (ANALYZE, BUFFERS) DELETE FROM orders"),
            (SqlGrammar::MySql, "EXPLAIN ANALYZE DELETE FROM orders"),
        ] {
            assert_eq!(access(sql, grammar), StatementAccess::Destructive, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn a_quoted_name_of_a_built_in_that_changes_state_still_writes() {
        assert_eq!(
            access(
                r#"SELECT pg_catalog."setval"('orders_id_seq', 1, false)"#,
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Write
        );
        assert_eq!(
            access(r#"SELECT "delete" FROM orders"#, SqlGrammar::PostgreSql),
            StatementAccess::Read
        );
    }

    #[test]
    fn a_table_named_like_a_routine_is_a_table() {
        assert_eq!(
            access(
                "CREATE TABLE dbo.event (id int); DELETE FROM orders;",
                SqlGrammar::MsSql
            ),
            StatementAccess::Destructive
        );
        assert_eq!(
            access(
                "CREATE OR REPLACE FUNCTION purge() RETURNS void AS $$ DELETE FROM orders $$ LANGUAGE sql",
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Write
        );
        assert_eq!(
            access(
                "CREATE OR ALTER PROCEDURE purge AS DELETE FROM orders",
                SqlGrammar::MsSql
            ),
            StatementAccess::Write
        );
    }

    #[test]
    fn show_create_only_reports() {
        for grammar in [SqlGrammar::MySql, SqlGrammar::ClickHouse] {
            assert_eq!(
                access("SHOW CREATE TABLE orders", grammar),
                StatementAccess::Read,
                "{grammar:?}"
            );
        }
    }

    #[test]
    fn a_table_named_statistics_is_updated_like_any_other() {
        for grammar in [SqlGrammar::Sqlite, SqlGrammar::PostgreSql, SqlGrammar::MySql] {
            assert_eq!(
                access("UPDATE statistics SET value = 0", grammar),
                StatementAccess::Destructive,
                "{grammar:?}"
            );
        }
    }

    #[test]
    fn a_routine_body_does_not_run_when_the_routine_is_created() {
        for (grammar, sql) in [
            (SqlGrammar::MsSql, "CREATE PROCEDURE purge AS DELETE FROM orders"),
            (SqlGrammar::MsSql, "ALTER PROCEDURE purge AS TRUNCATE TABLE orders"),
            (
                SqlGrammar::Sqlite,
                "CREATE TRIGGER t AFTER INSERT ON a BEGIN DELETE FROM b; END",
            ),
            (
                SqlGrammar::PostgreSql,
                "CREATE FUNCTION purge() RETURNS void LANGUAGE sql AS $$ DELETE FROM orders $$",
            ),
        ] {
            assert_eq!(access(sql, grammar), StatementAccess::Write, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn a_mysql_conditional_comment_is_read_as_code() {
        assert_eq!(
            access("SELECT 1 /*! ; DROP TABLE orders */", SqlGrammar::MySql),
            StatementAccess::Destructive
        );
        for sql in [
            "SELECT 1 /*M!100000 , 2 */",
            "SELECT /*!40001 SQL_NO_CACHE */ * FROM orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Read, "{sql}");
        }
        // A server older than 99999 skips the SELECT and runs the SET.
        assert_eq!(
            access("/*!99999 SELECT */ SET GLOBAL read_only = 0", SqlGrammar::MySql),
            StatementAccess::Write
        );
    }

    #[test]
    fn an_executable_comment_ends_where_the_server_ends_it() {
        for sql in [
            "SELECT 1 /*!, '*/'; DROP TABLE orders; SELECT ' */",
            "SELECT 1 /*! -- */ '\n; DROP TABLE orders; -- '\n*/",
            "SELECT 1 /*! # */ '\n; DROP TABLE orders; -- '\n*/",
            "SELECT 1 /*! AS `*/`; DROP TABLE orders; SELECT ` */",
            "SELECT 1;\n/*! DROP TABLE orders;",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
    }

    #[test]
    fn a_skipped_executable_comment_ends_where_the_server_ends_it() {
        for sql in [
            "/*!99999 ' */ DROP TABLE orders -- '",
            "SELECT 1 /*!99999 /* */ ' */ ; DROP TABLE orders; -- '",
            "SELECT 1 /*M!999999 /* */ ' */ ; DROP TABLE orders; -- '",
            // MySQL reads `/*M!` as a plain comment, with no nesting.
            "SELECT 1 /*M! ' /* x */ ; DROP TABLE orders; -- '",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
    }

    #[test]
    fn executable_comments_are_read_for_every_server_version() {
        for sql in [
            "/*!40000 DELETE FROM orders */ /*!99999 WHERE id = 1 */",
            "/*!99999 ON */ DROP TABLE orders",
            "DELETE FROM orders /*!50700 WHERE id = 1 */",
            "DELETE FROM orders /*M!100000 WHERE id = 1 */",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
    }

    #[test]
    fn a_mysql_81_dollar_quote_ends_where_the_server_ends_it() {
        for sql in [
            "CREATE PROCEDURE p() LANGUAGE JAVASCRIPT AS $$ /* $$; DROP TABLE orders; -- */",
            // A `$` that breaks a partial match of `$a$` cannot start one.
            "CREATE FUNCTION f() RETURNS int LANGUAGE JAVASCRIPT AS $a$ $$a$ /* $a$; DROP TABLE orders; -- */",
            "CREATE PROCEDURE p() LANGUAGE JAVASCRIPT /*!80100 AS $$ */ ' $$ */; DROP TABLE orders; -- '",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
        for sql in ["SELECT a$b$c, t.$x$ FROM t", "SELECT '$$; DROP TABLE orders' FROM t"] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Read, "{sql}");
        }
    }

    #[test]
    fn a_line_only_a_client_reads_as_delimiter_is_sql_to_the_server() {
        for sql in [
            "BEGIN NOT ATOMIC SELECT 1 /*!99999 ' */ ;\ndelimiter : LOOP DROP TABLE t; LEAVE delimiter; END LOOP;\nEND -- ' */",
            "BEGIN NOT ATOMIC SELECT 'a\\' ;\ndelimiter : LOOP DROP TABLE t; LEAVE delimiter; END LOOP;\nEND -- '",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
    }

    #[test]
    fn a_name_quote_the_session_sql_mode_sets_takes_the_stricter_reading() {
        for sql in [
            // ANSI_QUOTES: `"y\"` is a name, so the DROP stands outside it.
            r#"SELECT 'a\' , ' AS "y\" ; DROP TABLE t ; -- " AS b, '\''"#,
            // MariaDB's MSSQL mode reads `[a']` as a name.
            "SELECT 1 AS [a'] ; DROP TABLE t ; -- ']",
        ] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive, "{sql}");
        }
    }

    #[test]
    fn each_piece_a_client_sends_is_read_on_its_own() {
        // The editor reads the third line as part of the statement; split
        // again with `;` as the delimiter, it is a DELIMITER line, and the
        // last line goes alone.
        let batch = "SELECT 1;\nDELIMITER ; /*!99999 '*/ `' */\nSELECT 1 /*!99999 ' */ ; DROP TABLE t; -- ` ' */";
        assert_eq!(access(batch, SqlGrammar::MySql), StatementAccess::Destructive);
    }

    #[test]
    fn a_galera_node_runs_99997_comments() {
        assert_eq!(
            access(
                "/*M! /*!99997 DROP TABLE orders -- */ SELECT 1 -- \n*/",
                SqlGrammar::MySql
            ),
            StatementAccess::Destructive
        );
    }

    #[test]
    fn a_quote_that_only_one_reading_closes_takes_the_stricter_reading() {
        // With backslash escapes the DELETE sits inside the string; the
        // server may run with them off.
        let sql = r"SELECT 'a\'; DELETE FROM orders; -- '";
        assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Destructive);
        assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Destructive);
    }
}
