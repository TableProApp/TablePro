use std::collections::HashMap;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{ScriptPlan, ScriptToken, ScriptTokenKind};
use crate::sql_syntax::state_changing_functions::changes_state;
use crate::unicode_blank::is_blank;

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

/// T-SQL has no SHOW, EXPLAIN, DESCRIBE, TABLE or VALUES statement: such
/// a word is a name there, `SHOW:` a label in front of any statement, and
/// `SHOW 'x'` opening a batch runs a procedure called SHOW.
const TSQL_READ_VERBS: [&str; 2] = ["SELECT", "WITH"];

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

/// The clause words T-SQL reserves, so none of them can be a name that
/// ends a statement. ON and KEY are reserved but also end one (`SET
/// NOCOUNT ON`, `CLOSE MASTER KEY`), so ON leads in only before a foreign
/// key's referential action, and KEY never does. BEFORE, AFTER, INSTEAD
/// and DO are names there outside a trigger, whose body never runs on
/// creation anyway.
const TSQL_CLAUSE_WORDS: [&str; 9] = ["THEN", "FOR", "OF", "GRANT", "REVOKE", "DENY", "AND", "OR", "NOT"];

/// What a T-SQL DROP statement drops and an ALTER's DROP clause never
/// does, so `DROP TABLE` after an ALTER with no `;` starts a statement.
const TSQL_DROPPED_OBJECTS: [&str; 24] = [
    "TABLE",
    "VIEW",
    "PROCEDURE",
    "PROC",
    "FUNCTION",
    "TRIGGER",
    "INDEX",
    "SCHEMA",
    "DATABASE",
    "TYPE",
    "SEQUENCE",
    "SYNONYM",
    "USER",
    "LOGIN",
    "ROLE",
    "ASSEMBLY",
    "AGGREGATE",
    "DEFAULT",
    "RULE",
    "STATISTICS",
    "EXTERNAL",
    "FULLTEXT",
    "XML",
    "SECURITY",
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
    match grammar {
        SqlGrammar::Redis => return crate::sql_syntax::redis::script_access(sql),
        SqlGrammar::Mongo => return crate::sql_syntax::mongo::script_access(sql),
        _ => {}
    }
    let written = access_as_sent(sql, grammar, CLIENT_SPLITS);
    // PostgreSQL and SQLite read these characters as part of a name, or refuse them.
    let letters = matches!(grammar, SqlGrammar::PostgreSql | SqlGrammar::Sqlite);
    if written == StatementAccess::Destructive || letters || !sql.contains(may_be_space) {
        return written;
    }
    written.max(access_as_sent(&sql.replace(may_be_space, " "), grammar, CLIENT_SPLITS))
}

// SQL Server ends a word at a control character, a non-ASCII space or a zero-width character, so
// `NEXT\u{1}VALUE FOR` takes a number from a sequence; the lexer reads them as punctuation or letters.
fn may_be_space(character: char) -> bool {
    !character.is_ascii_whitespace()
        && (character.is_whitespace()
            || character.is_control()
            || matches!(character, '\u{200b}'..='\u{200f}' | '\u{2060}'..='\u{2064}' | '\u{feff}'))
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

/// A server may take a Unicode blank inside a word for a space or for
/// part of the name, so both readings count and the stricter stands.
fn access_of(sql: &str, grammar: SqlGrammar, tokens: &[ScriptToken]) -> StatementAccess {
    let code = code_of(sql, tokens);
    let whole = access_of_code(&code, grammar);
    let blanks_inside = code
        .iter()
        .any(|token| token.kind == Kind::Word && token.text.contains(is_blank));
    match blanks_inside {
        true => whole.max(access_of_code(&split_at_blanks(&code), grammar)),
        false => whole,
    }
}

fn access_of_code(code: &[Code<'_>], grammar: SqlGrammar) -> StatementAccess {
    let code = explained_pragma(code, grammar);
    if code.iter().all(|token| token.kind == Kind::End) || plans_only(code, grammar) {
        return StatementAccess::Read;
    }
    if destructive(code, grammar) {
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
/// could hold a statement after one. A quoted option name may be
/// PostgreSQL's `("analyze")`, and SQLite applies a PRAGMA while it
/// compiles the EXPLAIN.
fn plans_only(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    grammar != SqlGrammar::MsSql
        && code
            .first()
            .is_some_and(|first| first.is_word(&["EXPLAIN", "DESCRIBE", "DESC"]))
        && !code.iter().any(|token| token.is_word(&["ANALYZE", "ANALYSE"]))
        && !quotes_an_option(code, grammar)
        && code.iter().rev().skip(1).all(|token| token.kind != Kind::End)
}

/// PostgreSQL takes a quoted name for an option too, so
/// `EXPLAIN ("analyze")` runs the statement, and `U&"\0061nalyze"`
/// spells the same name. No option needs quotes, so a list that has them
/// may run what it explains. A parenthesis that opens on a query is that
/// query, not a list.
fn quotes_an_option(code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    code.get(1).is_some_and(|second| second.kind == Kind::Open)
        && !code.get(2..).is_some_and(|rest| opens_as_read(rest, grammar))
        && code
            .iter()
            .skip(2)
            .take_while(|token| token.kind != Kind::Close || token.depth > 0)
            .any(|token| token.kind == Kind::Quoted)
}

/// SQLite applies a pragma such as `foreign_keys = OFF` while it compiles
/// the statement, and EXPLAIN compiles what it explains, so an explained
/// pragma is read as the pragma itself.
fn explained_pragma<'code, 'sql>(code: &'code [Code<'sql>], grammar: SqlGrammar) -> &'code [Code<'sql>] {
    if grammar != SqlGrammar::Sqlite {
        return code;
    }
    let explained = match code {
        [explain, query, plan, rest @ ..]
            if explain.is_word(&["EXPLAIN"]) && query.is_word(&["QUERY"]) && plan.is_word(&["PLAN"]) =>
        {
            rest
        }
        [explain, rest @ ..] if explain.is_word(&["EXPLAIN"]) => rest,
        _ => return code,
    };
    match explained.first().is_some_and(|first| first.is_word(&["PRAGMA"])) {
        true => explained,
        false => code,
    }
}

/// Whether a word in `part` writes wherever it stands. Every SHOW only
/// reports, `SHOW CREATE TABLE` included.
fn writes(part: &[Code<'_>], grammar: SqlGrammar) -> bool {
    if grammar != SqlGrammar::MsSql && part.first().is_some_and(|first| first.is_word(&["SHOW"])) {
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
                    || calls_mutator(part, index, grammar))
        }
        Kind::Quoted => calls_mutator(part, index, grammar),
        _ => false,
    })
}

/// A call of a built-in that changes state, its name quoted or not.
/// PostgreSQL decodes the escapes in `U&"set\0076al"` before it looks the
/// name up, under an escape character `UESCAPE` may change, so a name
/// spelled that way is compared with nothing and may be any of them.
fn calls_mutator(part: &[Code<'_>], index: usize, grammar: SqlGrammar) -> bool {
    let arguments = match decodes_unicode_names(grammar) && spelled_in_escapes(part, index) {
        true => after_uescape(part, index + 1),
        false if changes_state(part[index].text) => index + 1,
        false => return false,
    };
    part.get(arguments).is_some_and(|next| next.kind == Kind::Open)
}

/// The grammars whose scanner is PostgreSQL's, which reads `U&"…"`.
fn decodes_unicode_names(grammar: SqlGrammar) -> bool {
    matches!(grammar, SqlGrammar::PostgreSql | SqlGrammar::DuckDb)
}

/// A `U&"…"` name, whose prefix the lexer reads as the word `U` and `&`,
/// written with nothing between them, since `u & "f"(1)` is an AND.
fn spelled_in_escapes(part: &[Code<'_>], index: usize) -> bool {
    part[index].kind == Kind::Quoted
        && index >= 2
        && part[index - 1].kind == Kind::Other
        && part[index - 1].text == "&"
        && part[index - 2].is_word(&["U"])
        && part[index - 2].text.as_ptr() as usize + 3 == part[index].text.as_ptr() as usize
}

/// The index past a `UESCAPE '!'` at `index`, or `index` where there is
/// none. A string can go on in another on the next line, so it is as
/// many tokens as stand there.
fn after_uescape(part: &[Code<'_>], index: usize) -> usize {
    if !part.get(index).is_some_and(|word| word.is_word(&["UESCAPE"])) {
        return index;
    }
    let strings = part[index + 1..].iter().take_while(|token| token.kind == Kind::Literal);
    index + 1 + strings.count()
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
        Kind::Word if grammar == SqlGrammar::MsSql => is(first.text, &TSQL_READ_VERBS),
        // CQL's LIST ROLES, LIST USERS and LIST PERMISSIONS report.
        Kind::Word => is(first.text, &READ_VERBS) || (grammar == SqlGrammar::Cql && is(first.text, &["LIST"])),
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
    /// A string or a dollar-quoted body.
    Literal,
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
                ScriptTokenKind::StringLiteral | ScriptTokenKind::DollarQuoted => Kind::Literal,
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

/// `code` with each word cut where it holds a Unicode blank.
fn split_at_blanks<'a>(code: &[Code<'a>]) -> Vec<Code<'a>> {
    code.iter()
        .flat_map(|token| {
            let pieces: Vec<Code<'a>> = match token.kind {
                Kind::Word => token
                    .text
                    .split(is_blank)
                    .filter(|piece| !piece.is_empty())
                    .map(|text| Code { text, ..*token })
                    .collect(),
                _ => vec![*token],
            };
            pieces
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
    let starts = statement_starts(code, grammar);
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

fn statement_starts(code: &[Code<'_>], grammar: SqlGrammar) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut lead: Option<&str> = None;
    for (index, token) in code.iter().enumerate() {
        let opens = match index.checked_sub(1).map(|before| &code[before]) {
            _ if is_call(code, index) => false,
            None => token.kind == Kind::Word,
            Some(before) if token.is_word(&["DELETE", "UPDATE"]) && before.kind == Kind::Open => true,
            Some(before) if token.depth == 0 && token.is_word(&STATEMENT_VERBS) => {
                let led_in = leads_in(before, &code[index..], grammar) || before.kind == Kind::Comma;
                let alters = lead.is_some_and(|lead| is(lead, &["ALTER"]))
                    && token.is_word(&["DROP", "ALTER"])
                    && !(grammar == SqlGrammar::MsSql && drops_an_object(&code[index..]));
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

/// Whether `before` keeps the verb at `code[0]` inside its statement.
fn leads_in(before: &Code<'_>, code: &[Code<'_>], grammar: SqlGrammar) -> bool {
    if grammar != SqlGrammar::MsSql {
        return before.is_word(&CLAUSE_WORDS);
    }
    if !before.is_word(&["ON"]) {
        return before.is_word(&TSQL_CLAUSE_WORDS);
    }
    let word = |at: usize, set: &[&str]| code.get(at).is_some_and(|token| token.is_word(set));
    word(0, &["DELETE", "UPDATE"])
        && (word(1, &["CASCADE"])
            || (word(1, &["SET"]) && word(2, &["NULL", "DEFAULT"]))
            || (word(1, &["NO"]) && word(2, &["ACTION"])))
}

/// A DROP at `code[0]` that names a kind of object only a DROP statement
/// takes.
fn drops_an_object(code: &[Code<'_>]) -> bool {
    code[0].is_word(&["DROP"]) && code.get(1).is_some_and(|kind| kind.is_word(&TSQL_DROPPED_OBJECTS))
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
    !assigns && name.is_some_and(|name| sqlite_pragma_reports(name.text))
}

/// Whether the SQLite pragma `name` only reports, whatever argument it
/// is given. Any other pragma can change the database or the connection.
pub fn sqlite_pragma_reports(name: &str) -> bool {
    is(name, &REPORTING_PRAGMAS)
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
                "SELECT replace(name, 'a', 'b') FROM orders",
                "",
                "-- only a note",
            ] {
                assert_eq!(access(sql, grammar), StatementAccess::Read, "{grammar:?}: {sql}");
            }
        }
        for grammar in SqlGrammar::SQL
            .into_iter()
            .filter(|grammar| *grammar != SqlGrammar::MsSql)
        {
            assert_eq!(
                access("EXPLAIN SELECT * FROM orders", grammar),
                StatementAccess::Read,
                "{grammar:?}"
            );
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
            (SqlGrammar::Cql, "LIST ROLES"),
            (SqlGrammar::Cql, "DESCRIBE KEYSPACES"),
            (SqlGrammar::Cql, "SELECT $$DELETE FROM t$$ AS note FROM t"),
            (
                SqlGrammar::Cql,
                "SELECT * FROM t WHERE a = 1 ALLOW FILTERING // DROP TABLE t",
            ),
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
            (
                SqlGrammar::Cql,
                "BEGIN BATCH INSERT INTO t (a) VALUES (1); UPDATE t SET b = 2 WHERE a = 1; APPLY BATCH",
            ),
            (SqlGrammar::Cql, "USE shop"),
            (SqlGrammar::Cql, "LIST ROLES; DROP ROLE r"),
        ] {
            assert!(access(sql, grammar) >= StatementAccess::Write, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn a_dash_comment_after_an_empty_exponent_is_read_both_ways() {
        for sql in [
            "SELECT 1E--1 DROP TABLE t",
            "SELECT 1.5e--1; DROP TABLE t",
            "SELECT .5E--1 DELETE FROM t",
            "SELECT a1E+1E--1 DROP TABLE t",
            "SELECT 1E--DROP TABLE t",
            "SELECT 1E--'\nDROP TABLE t --'",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Destructive, "{sql}");
        }
        assert_eq!(
            access("SELECT 1E--1 INTO t2 FROM t", SqlGrammar::MsSql),
            StatementAccess::Write
        );
        for sql in [
            "SELECT 1 --1 DROP TABLE t",
            "SELECT 1--1 DROP TABLE t",
            "SELECT a1E--1 DROP TABLE t",
            "SELECT 0x1E--1 DROP TABLE t",
            "SELECT 1E1--1 DROP TABLE t",
            "SELECT 1E---1 DROP TABLE t",
            "SELECT 1E+1E--1 DROP TABLE t",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Read, "{sql}");
        }
        assert_eq!(
            access("SELECT 1E--1 DROP TABLE t", SqlGrammar::PostgreSql),
            StatementAccess::Read
        );
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
                "SELECT * FROM orders FOR UPDATE",
                "GRANT SELECT, UPDATE, DELETE ON orders TO someone",
                "CREATE TRIGGER t AFTER UPDATE OF total ON orders FOR EACH ROW EXECUTE FUNCTION f()",
                "SELECT 'DROP TABLE orders'",
            ] {
                assert_ne!(access(sql, grammar), StatementAccess::Destructive, "{grammar:?}: {sql}");
            }
        }
        // T-SQL has no ON CONFLICT, and DO is a name there.
        for grammar in SqlGrammar::SQL
            .into_iter()
            .filter(|grammar| *grammar != SqlGrammar::MsSql)
        {
            let sql = "INSERT INTO orders VALUES (1) ON CONFLICT (id) DO UPDATE SET total = 0";
            assert_ne!(access(sql, grammar), StatementAccess::Destructive, "{grammar:?}: {sql}");
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
    fn a_character_sql_server_takes_for_a_space_is_read_as_one() {
        for blank in [
            '\u{1}', '\u{8}', '\u{1f}', '\u{7f}', '\u{85}', '\u{a0}', '\u{200b}', '\u{feff}', '\u{3000}',
        ] {
            for sql in [
                format!("SELECT NEXT{blank}VALUE FOR dbo.order_ids"),
                format!("SELECT NEXT VALUE{blank}FOR dbo.order_ids"),
                format!("SELECT id{blank}INTO{blank}copies FROM orders"),
            ] {
                assert_eq!(access(&sql, SqlGrammar::MsSql), StatementAccess::Write, "{sql:?}");
            }
            let sql = format!("SELECT 1{blank}DROP{blank}TABLE orders");
            assert_eq!(access(&sql, SqlGrammar::MsSql), StatementAccess::Destructive, "{sql:?}");
            for sql in [
                format!("SELECT id{blank}FROM orders"),
                format!("SELECT 'NEXT{blank}VALUE FOR s', [DROP{blank}TABLE] FROM orders -- a{blank}DROP"),
            ] {
                assert_eq!(access(&sql, SqlGrammar::MsSql), StatementAccess::Read, "{sql:?}");
            }
        }
        assert_eq!(
            access("SELECT caf\u{e9}, \u{540d}\u{524d} FROM orders", SqlGrammar::MsSql),
            StatementAccess::Read
        );
        // A blank inside a word is read both ways on every engine, and the stricter reading stands.
        assert_eq!(
            access("SELECT foo\u{200b}INTO\u{200b}bar FROM orders", SqlGrammar::PostgreSql),
            StatementAccess::Write
        );
    }

    #[test]
    fn an_explain_option_that_is_quoted_runs_the_statement() {
        for sql in [
            r#"EXPLAIN ("analyze") DELETE FROM orders"#,
            r#"EXPLAIN (VERBOSE, "analyze") DELETE FROM orders"#,
            r#"EXPLAIN (U&"an\0061lyze") DELETE FROM orders"#,
        ] {
            assert_ne!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Read, "{sql}");
        }
        assert_eq!(
            access(
                r#"EXPLAIN (FORMAT JSON) SELECT "id" FROM orders"#,
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Read
        );
    }

    #[test]
    fn explain_pragma_reads_only_when_the_pragma_does() {
        for sql in [
            "EXPLAIN PRAGMA query_only=ON",
            "EXPLAIN QUERY PLAN PRAGMA hard_heap_limit = 1",
            "explain pragma foreign_keys = off",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Write, "{sql}");
        }
        assert_eq!(
            access("EXPLAIN PRAGMA table_info(orders)", SqlGrammar::Sqlite),
            StatementAccess::Read
        );
        assert_eq!(
            access("EXPLAIN QUERY PLAN SELECT * FROM orders", SqlGrammar::Sqlite),
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
        // A MySQL one also runs 50700 and skips 90000, as no other server does.
        assert_eq!(
            access(
                "/*!50700 # */ \"\n*/ /*!90000 ' */ /*!99997 DROP TABLE orders # */ ' \"\n*/",
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

    #[test]
    fn a_quote_inside_a_sqlite_parameter_opens_no_string() {
        for sql in [
            "WITH c AS (SELECT $1(')) DELETE FROM orders --'",
            "WITH c AS (SELECT $a::b(')) DELETE FROM orders --'",
            "WITH c AS (SELECT @a(')) DELETE FROM orders --'",
            "WITH c AS (SELECT :a(')) DELETE FROM orders --'",
            "WITH c AS (SELECT #a(')) DELETE FROM orders --'",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Destructive, "{sql}");
        }
        for sql in [
            "SELECT $1('); ATTACH DATABASE 'other.db' AS other; --'",
            "SELECT $1('); VACUUM INTO 'copy.db'; --'",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Write, "{sql}");
        }
        for sql in [
            "SELECT $1, $name, :name, @name FROM orders",
            "SELECT $1( '; DELETE FROM orders; --')",
            "SELECT a$1('; DELETE FROM orders; --')",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Read, "{sql}");
        }
    }

    #[test]
    fn a_string_that_continues_an_escape_string_is_read_as_one() {
        // The server carries `E'x'` on into a string on the next line and
        // reads that with backslash escapes on, so the first `\'` is an
        // escaped quote and the COMMIT is code.
        for sql in [
            "SELECT E'x'\n'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
            "SELECT e'x' -- note\r\n  -- note\n\t'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
            "SELECT E'x'\n'y'\n'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
        ] {
            for grammar in [SqlGrammar::PostgreSql, SqlGrammar::DuckDb] {
                assert_eq!(
                    access(sql, grammar),
                    StatementAccess::Destructive,
                    "{grammar:?}: {sql:?}"
                );
            }
        }
        for sql in [
            "SELECT E'x'\n'\\'; DELETE FROM orders; --'",
            "SELECT E'a\\'b'\n'c\\'d' FROM orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Read, "{sql:?}");
        }
    }

    #[test]
    fn a_unicode_blank_before_a_keyword_does_not_hide_it() {
        for (sql, expected) in [
            ("\u{feff}DROP TABLE t", StatementAccess::Destructive),
            ("SELECT 1;\u{feff}DELETE FROM t", StatementAccess::Destructive),
            (
                "WITH x AS (SELECT 1) \u{feff}DELETE FROM t",
                StatementAccess::Destructive,
            ),
            (
                "WITH x AS (SELECT 1) \u{feff}INSERT \u{feff}INTO t VALUES (1)",
                StatementAccess::Write,
            ),
            ("\u{feff}SELECT 1", StatementAccess::Read),
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), expected, "{sql:?}");
        }
        // Whether SQL Server or ClickHouse skip such a character is not
        // known here, so the stricter reading stands.
        for grammar in [SqlGrammar::MsSql, SqlGrammar::ClickHouse] {
            for sql in [
                "SELECT 1\n\u{feff}DROP TABLE t",
                "SELECT 1\n\u{200b}DROP TABLE t",
                "SELECT 1\n\u{a0}DROP TABLE t",
            ] {
                assert_eq!(
                    access(sql, grammar),
                    StatementAccess::Destructive,
                    "{grammar:?}: {sql:?}"
                );
            }
            assert!(
                access("SEL\u{feff}ECT 1", grammar) >= StatementAccess::Write,
                "{grammar:?}"
            );
        }
    }

    #[test]
    fn a_sql_server_batch_that_opens_with_the_name_show_is_not_a_read() {
        for sql in [
            "SHOW: SELECT 1",
            "SHOW: UPDATE orders SET total = 0 WHERE id = 1",
            "SHOW: COMMIT TRANSACTION UPDATE orders SET total = 0 WHERE id = 1 BEGIN TRANSACTION",
            "SHOW: EXEC('DROP TABLE orders')",
            "SHOW: EXEC xp_cmdshell 'whoami'",
            "SELECT 1; show : BACKUP DATABASE shop TO DISK = 'x'",
            "SHOW INSERT INTO orders VALUES (1)",
            "EXPLAIN 'x'",
            "DESCRIBE orders",
            "VALUES (1)",
            "TABLE orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Write, "{sql}");
        }
        assert_eq!(
            access("SHOW: DELETE FROM orders", SqlGrammar::MsSql),
            StatementAccess::Destructive
        );
    }

    #[test]
    fn an_explain_with_a_quoted_option_may_run_what_it_explains() {
        for (sql, expected) in [
            ("EXPLAIN (\"analyze\") DELETE FROM orders", StatementAccess::Destructive),
            (
                "EXPLAIN (COSTS off, \"analyze\" true) DELETE FROM orders",
                StatementAccess::Destructive,
            ),
            (
                "EXPLAIN (U&\"\\0061nalyze\") DELETE FROM orders",
                StatementAccess::Destructive,
            ),
            (
                "EXPLAIN (\"analyze\") SELECT pg_terminate_backend(42)",
                StatementAccess::Write,
            ),
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), expected, "{sql}");
        }
        for sql in [
            "EXPLAIN (COSTS false) DELETE FROM \"analyze\"",
            "EXPLAIN (FORMAT 'json') DELETE FROM orders",
            "EXPLAIN (WITH gone AS (SELECT * FROM \"orders\") SELECT * FROM gone)",
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Read, "{sql}");
        }
    }

    #[test]
    fn an_explained_pragma_is_read_as_the_pragma_on_sqlite() {
        for sql in [
            "EXPLAIN PRAGMA foreign_keys = OFF",
            "explain pragma main.trusted_schema = ON",
            "EXPLAIN QUERY PLAN PRAGMA writable_schema(ON)",
            "EXPLAIN /* plan */ PRAGMA hard_heap_limit = 1",
            "EXPLAIN QUERY PLAN PRAGMA recursive_triggers = ON",
            "EXPLAIN PRAGMA optimize",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Write, "{sql}");
        }
        for sql in [
            "EXPLAIN PRAGMA table_info(orders)",
            "EXPLAIN QUERY PLAN PRAGMA main.index_list('orders')",
            "EXPLAIN QUERY PLAN SELECT * FROM orders",
            "EXPLAIN DELETE FROM orders",
        ] {
            assert_eq!(access(sql, SqlGrammar::Sqlite), StatementAccess::Read, "{sql}");
        }
    }

    #[test]
    fn a_function_that_runs_sql_text_or_signals_writes() {
        for sql in [
            "SELECT dblink('host=db', 'DELETE FROM orders')",
            "SELECT * FROM dblink('host=db', 'DELETE FROM orders') AS t(n int)",
            "SELECT dblink_send_query('c', 'DELETE FROM orders')",
            "SELECT dblink_open('c', 'cur', 'SELECT 1')",
            "SELECT query_to_xml('DELETE FROM orders RETURNING *', true, false, '')",
            "SELECT ts_stat('DELETE FROM orders RETURNING note::tsvector')",
            "SELECT lo_creat(-1)",
            "SELECT lowrite(0, 'x')",
            "SELECT lo_truncate(0, 0)",
            "SELECT pg_notify('jobs', 'run')",
            "SELECT pg_advisory_lock(1)",
            "SELECT pg_logical_slot_get_changes('s', NULL, NULL)",
            "SELECT pg_replication_origin_create('o')",
            "SELECT pg_stat_reset_shared('bgwriter')",
            "SELECT pg_wal_replay_pause()",
            "SELECT gin_clean_pending_list('i'::regclass)",
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Write, "{sql}");
        }
        for sql in ["SELECT GET_LOCK('l', 1)", "SELECT release_all_locks()"] {
            assert_eq!(access(sql, SqlGrammar::MySql), StatementAccess::Write, "{sql}");
        }
        assert_eq!(
            access(
                "SELECT dblink_build_sql_insert('t', '1', 1, '{1}', '{2}')",
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Read
        );
    }

    #[test]
    fn a_call_of_a_name_spelled_in_escapes_writes() {
        for sql in [
            r#"SELECT U&"set\0076al"('orders_id_seq', 1, false)"#,
            r#"SELECT pg_catalog.u&"pg_terminate_backen\0064"(pid) FROM pg_stat_activity"#,
            r#"SELECT U&"pg_terminate_backen\+000064" /* all */ (pid) FROM pg_stat_activity"#,
            r#"SELECT U&"setv!0061l" UESCAPE '!' ('orders_id_seq', 1, false)"#,
            r#"SELECT U&"setv!0061l" uescape E'!'('orders_id_seq', 1, false)"#,
            r#"SELECT U&"setv!0061l" UESCAPE $$!$$ ('orders_id_seq', 1, false)"#,
            "SELECT U&\"setv!0061l\" UESCAPE '!'\n'' ('orders_id_seq', 1, false)",
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Write, "{sql}");
        }
        for sql in [
            r#"SELECT U&"d\0061ta", u & "mask" FROM orders"#,
            r#"SELECT U&"d!0061ta" UESCAPE '!' FROM orders WHERE id IN (1, 2)"#,
            r#"SELECT U&'d\0061ta', count(*) FROM orders"#,
            r#"SELECT U&"pg_terminate_backen\0064" FROM pg_proc"#,
        ] {
            assert_eq!(access(sql, SqlGrammar::PostgreSql), StatementAccess::Read, "{sql}");
        }
        assert_eq!(
            access(
                r#"SELECT U&"price" UESCAPE '!' + (1) FROM items"#,
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Read
        );
        // No other grammar decodes a name, and a spaced `&` is an AND.
        assert_eq!(
            access(r#"SELECT U & "f"(1) FROM t"#, SqlGrammar::Sqlite),
            StatementAccess::Read
        );
        assert_eq!(
            access(
                r#"SELECT u & "abs"(-3) FROM (VALUES (7)) AS t(u)"#,
                SqlGrammar::PostgreSql
            ),
            StatementAccess::Read
        );
    }

    #[test]
    fn a_sql_server_statement_that_ends_in_a_clause_word_still_ends() {
        for sql in [
            "SET NOCOUNT ON\nDROP TABLE orders",
            "SET XACT_ABORT ON\nTRUNCATE TABLE orders",
            "SET IDENTITY_INSERT orders ON\nDELETE FROM orders",
            "SET IDENTITY_INSERT orders ON\nDELETE orders",
            "SET NOCOUNT ON\nUPDATE orders SET total = 0",
            "SELECT 1\nSET NOCOUNT ON -- quiet\nDROP TABLE orders",
            "CLOSE MASTER KEY\nDROP TABLE orders",
            "SELECT * FROM before\nDROP TABLE orders",
            "SELECT * FROM after\nDELETE FROM orders",
            "SELECT * FROM instead\nTRUNCATE TABLE orders",
            "SELECT * FROM do\nUPDATE orders SET total = 0",
            "ALTER TABLE t ADD x int\nDROP TABLE y",
            "ALTER TABLE t ADD x int\nDELETE FROM y",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Destructive, "{sql}");
        }
        for sql in [
            "ALTER TABLE lines ADD CONSTRAINT fk FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE",
            "ALTER TABLE lines ADD CONSTRAINT fk FOREIGN KEY (order_id) REFERENCES orders (id) ON UPDATE SET NULL",
            "ALTER TABLE lines ADD CONSTRAINT fk FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE NO ACTION",
            "SET NOCOUNT ON\nDELETE FROM orders WHERE id = 1",
            "ALTER TABLE orders DROP COLUMN note",
            "ALTER TABLE orders DROP CONSTRAINT orders_pk",
            "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE",
            "DECLARE c CURSOR FOR SELECT id FROM orders FOR UPDATE",
        ] {
            assert_eq!(access(sql, SqlGrammar::MsSql), StatementAccess::Write, "{sql}");
        }
    }
}
