//! Running statements on a connection and reading what they return.
//!
//! Everything here blocks: it runs on a thread of the blocking pool
//! with a connection the call holds. A result is read a chunk at a time
//! off DuckDB's streaming result, so a read stops where the reader stops
//! instead of DuckDB producing the whole result first.

use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::sync::Arc;

use duckdb::arrow::array::{Array, StructArray};
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptDiagnostic, ScriptPlan, ScriptToken, ScriptTokenKind};
use tablepro_core::statement::{BoundParam, Statement};
use tablepro_core::value::Value;
use tablepro_core::{DriverError, QueryResult, ResultEvent, RowLimit, Truncation, UnsupportedFeature};
use tokio::sync::mpsc;

use crate::decode::value_at;
use crate::duck_type::DuckType;
use crate::encode::bind_all;
use crate::errors::{is_parse_error, map_error};
use crate::instance::{Link, attach_unless_open};

/// How many rows travel in one `Rows` event: enough that a large read
/// is not one await per row, few enough that the first rows show at
/// once.
const ROWS_PER_EVENT: usize = 256;

/// What a run of statements did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct StreamOutcome {
    pub rows: u64,
    /// The reader stopped taking events, so the rest of the run was
    /// skipped.
    pub consumer_gone: bool,
    /// A stop came between two statements, so the rest was not run.
    pub halted: bool,
}

/// The columns a statement returns, by name and by DuckDB type.
struct Shape {
    names: Vec<String>,
    types: Vec<DuckType>,
}

impl Shape {
    fn of(statement: &duckdb::Statement<'_>) -> Self {
        let schema = statement.schema();
        let names: Vec<String> = schema.fields().iter().map(|field| field.name().clone()).collect();
        let types = (0..names.len())
            .map(|index| DuckType::from_logical(&statement.column_logical_type(index)))
            .collect();
        Self { names, types }
    }

    fn columns(&self) -> Arc<[ResultColumn]> {
        self.names
            .iter()
            .zip(&self.types)
            .map(|(name, duck)| ResultColumn::new(name.clone(), duck.column_type()))
            .collect()
    }

    fn rows(&self, chunk: &StructArray, from: usize, to: usize) -> Vec<Vec<Value>> {
        (from..to)
            .map(|row| {
                chunk
                    .columns()
                    .iter()
                    .zip(&self.types)
                    .map(|(column, duck)| value_at(column.as_ref(), duck, row))
                    .collect()
            })
            .collect()
    }
}

/// Start `sql` with `params` on DuckDB's streaming result, giving back
/// the statement to read from and its columns.
fn start<'c>(link: &'c Link, sql: &str, params: &[BoundParam]) -> Result<(duckdb::Statement<'c>, Shape), DriverError> {
    let values = bind_all(params)?;
    let mut statement = link.connection.prepare(sql).map_err(map_error)?;
    drop(
        statement
            .stream_arrow(duckdb::params_from_iter(values.iter()))
            .map_err(map_error)?,
    );
    let shape = Shape::of(&statement);
    Ok((statement, shape))
}

fn next_chunk(statement: &duckdb::Statement<'_>) -> Result<Option<StructArray>, DriverError> {
    statement.step().map_err(map_error)
}

/// A read the app built, kept to `limit` rows, and whether there were
/// more.
pub(crate) fn collect(link: &Link, statement: &Statement, limit: Option<RowLimit>) -> Result<QueryResult, DriverError> {
    let (running, shape) = start(link, statement.sql(), statement.params())?;
    let keep = limit.map(|limit| usize::try_from(limit.get()).unwrap_or(usize::MAX));
    let mut rows = Vec::new();
    let mut truncated = false;
    while let Some(chunk) = next_chunk(&running)? {
        let room = keep.map_or(chunk.len(), |keep| keep.saturating_sub(rows.len()));
        rows.extend(shape.rows(&chunk, 0, room.min(chunk.len())));
        if room < chunk.len() {
            truncated = true;
            break;
        }
    }
    Ok(QueryResult::new(shape.columns(), rows).truncated(truncated))
}

/// The single number a count query returned.
pub(crate) fn count(link: &Link, statement: &Statement) -> Result<u64, DriverError> {
    let result = collect(link, statement, RowLimit::new(1))?;
    match result.cell(0, 0) {
        Some(value) => value
            .as_exact_u64()
            .ok_or_else(|| DriverError::Protocol(format!("a row count read as {value:?}"))),
        None => Err(DriverError::Protocol("the count returned no row".to_owned())),
    }
}

/// Run a statement the app built for its effect, giving the number of
/// rows it changed.
pub(crate) fn execute(link: &Link, statement: &Statement) -> Result<u64, DriverError> {
    let values = bind_all(statement.params())?;
    let mut prepared = link.connection.prepare(statement.sql()).map_err(map_error)?;
    let changed = prepared
        .execute(duckdb::params_from_iter(values.iter()))
        .map_err(map_error)?;
    u64::try_from(changed).map_err(|_| DriverError::Protocol("a row count past u64".to_owned()))
}

/// Run plain SQL with no result to read, such as BEGIN or COMMIT.
pub(crate) fn batch(link: &Link, sql: &str) -> Result<(), DriverError> {
    link.connection.execute_batch(sql).map_err(map_error)
}

/// Where a run's events go: the async side reads them off the channel
/// and hands each to the sink before taking the next, so a sink that
/// falls behind holds the run here.
pub(crate) struct Events {
    sender: mpsc::Sender<ResultEvent>,
    gone: bool,
}

impl Events {
    pub(crate) fn new(sender: mpsc::Sender<ResultEvent>) -> Self {
        Self { sender, gone: false }
    }

    /// Hand one event over; false once nobody reads any more.
    fn send(&mut self, event: ResultEvent) -> bool {
        if !self.gone && self.sender.blocking_send(event).is_err() {
            self.gone = true;
        }
        !self.gone
    }
}

/// Run SQL the user wrote, one statement after another, until one
/// fails, the reader goes or `halt` is raised. Each statement goes to
/// DuckDB alone, so each result set streams by itself.
pub(crate) fn run_script(
    link: &Link,
    sql: &str,
    limit: Option<RowLimit>,
    events: &mut Events,
    halt: &dyn Fn() -> bool,
) -> Result<StreamOutcome, DriverError> {
    let mut outcome = StreamOutcome::default();
    for statement in split_statements(sql) {
        if halt() {
            outcome.halted = true;
            break;
        }
        match attach_literal(statement) {
            Some(literal) => {
                // DuckDB leaves a HIDDEN database out of what it lists, so
                // no check could tell another window it is open.
                if attach_hides(statement) {
                    return Err(DriverError::Unsupported {
                        feature: UnsupportedFeature::HiddenAttach,
                    });
                }
                let targets = attach_targets(link, literal)?;
                let ran = attach_unless_open(link, &targets, || {
                    // A stop that came while the ATTACH waited its turn:
                    // DuckDB clears an interrupt as a statement starts.
                    if halt() {
                        return Ok(false);
                    }
                    run_statement(link, statement, &[], limit, events, &mut outcome).map(|()| true)
                })?;
                if !ran {
                    outcome.halted = true;
                    break;
                }
            }
            None => run_statement(link, statement, &[], limit, events, &mut outcome)?,
        }
        if outcome.consumer_gone {
            break;
        }
    }
    Ok(outcome)
}

/// Run a read the app built, every row of it.
pub(crate) fn run_bound(link: &Link, statement: &Statement, events: &mut Events) -> Result<StreamOutcome, DriverError> {
    let mut outcome = StreamOutcome::default();
    run_statement(link, statement.sql(), statement.params(), None, events, &mut outcome)?;
    Ok(outcome)
}

fn run_statement(
    link: &Link,
    sql: &str,
    params: &[BoundParam],
    limit: Option<RowLimit>,
    events: &mut Events,
    outcome: &mut StreamOutcome,
) -> Result<(), DriverError> {
    let (running, shape) = start(link, sql, params)?;
    match command_result(sql, &shape) {
        Some(Command::ChangedRows) => {
            let changed = match next_chunk(&running)? {
                Some(chunk) => shape.rows(&chunk, 0, chunk.len().min(1)).into_iter().next(),
                None => None,
            };
            while next_chunk(&running)?.is_some() {}
            let rows_affected = changed.and_then(|row| row.first().and_then(Value::as_exact_u64));
            outcome.consumer_gone = !events.send(ResultEvent::CommandCompleted { rows_affected });
            Ok(())
        }
        Some(Command::Nothing) => {
            while next_chunk(&running)?.is_some() {}
            outcome.consumer_gone = !events.send(ResultEvent::CommandCompleted { rows_affected: None });
            Ok(())
        }
        None => stream_rows(&running, &shape, limit, events, outcome),
    }
}

/// A statement DuckDB answers with a status rather than rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    /// One BIGINT `Count`: the rows an INSERT, UPDATE, DELETE, MERGE,
    /// COPY or CREATE TABLE AS changed. A plain CREATE answers with the
    /// same column and no row.
    ChangedRows,
    /// One BOOLEAN `Success` and no row: SET, ATTACH, DROP, a
    /// transaction statement and the like.
    Nothing,
}

/// The words a statement that returns rows starts with. A statement of
/// any other kind returns rows only through RETURNING. What CALL and
/// EXECUTE return is the function's or the prepared statement's, which
/// may be a `Count` or `Success` column of its own, so it stays rows.
const QUERY_WORDS: [&str; 14] = [
    "SELECT",
    "CALL",
    "EXECUTE",
    "VALUES",
    "FROM",
    "TABLE",
    "SHOW",
    "DESCRIBE",
    "DESC",
    "SUMMARIZE",
    "EXPLAIN",
    "PIVOT",
    "UNPIVOT",
    "PRAGMA",
];

/// What DuckDB's statement return type would say, read from the
/// columns it bound and the statement's words, since the duckdb crate
/// does not expose the return type itself.
fn command_result(sql: &str, shape: &Shape) -> Option<Command> {
    let queries = main_verb(sql).is_none_or(|verb| QUERY_WORDS.contains(&verb.as_str()));
    if queries || words(sql).iter().any(|word| word == "RETURNING") || shape.names.len() != 1 {
        return None;
    }
    match (shape.names[0].as_str(), &shape.types[0]) {
        ("Count", DuckType::Integer { .. }) => Some(Command::ChangedRows),
        ("Success", DuckType::Boolean) => Some(Command::Nothing),
        _ => None,
    }
}

fn stream_rows(
    running: &duckdb::Statement<'_>,
    shape: &Shape,
    limit: Option<RowLimit>,
    events: &mut Events,
    outcome: &mut StreamOutcome,
) -> Result<(), DriverError> {
    if !events.send(ResultEvent::ResultSetStarted {
        columns: shape.columns(),
    }) {
        outcome.consumer_gone = true;
        return Ok(());
    }
    let keep = limit.map_or(u64::MAX, RowLimit::get);
    let mut retained = 0u64;
    let mut truncation = Truncation::Complete;
    'chunks: while let Some(chunk) = next_chunk(running)? {
        let mut from = 0;
        while from < chunk.len() {
            if retained >= keep {
                truncation = Truncation::ReadPastLimit;
                break 'chunks;
            }
            let room = usize::try_from(keep - retained).unwrap_or(usize::MAX);
            let to = chunk.len().min(from + ROWS_PER_EVENT).min(from.saturating_add(room));
            let rows = shape.rows(&chunk, from, to);
            retained += rows.len() as u64;
            outcome.rows += rows.len() as u64;
            if !events.send(ResultEvent::Rows(rows)) {
                outcome.consumer_gone = true;
                return Ok(());
            }
            from = to;
        }
    }
    let mut closing = Vec::new();
    if truncation == Truncation::ReadPastLimit {
        closing.push(ResultEvent::RowLimitReached { retained });
    }
    closing.push(ResultEvent::ResultSetFinished {
        retained,
        total_rows: (truncation == Truncation::Complete).then_some(retained),
        truncation,
    });
    for event in closing {
        if !events.send(event) {
            outcome.consumer_gone = true;
            break;
        }
    }
    Ok(())
}

/// Whether the statement changes rows and returns no rows of its own,
/// so its one value is the number it changed.
pub(crate) fn changes_rows(sql: &str) -> bool {
    let changes = matches!(
        main_verb(sql).as_deref(),
        Some("INSERT" | "UPDATE" | "DELETE" | "MERGE" | "COPY" | "UPSERT")
    );
    changes && !words(sql).iter().any(|word| word == "RETURNING")
}

/// The statement's own verb, upper case: its first word, or past a WITH
/// clause the first word outside its parentheses that starts a
/// statement, as in `WITH src AS (...) INSERT INTO ...`.
fn main_verb(sql: &str) -> Option<String> {
    const VERBS: [&str; 15] = [
        "SELECT",
        "INSERT",
        "UPDATE",
        "DELETE",
        "MERGE",
        "UPSERT",
        "VALUES",
        "FROM",
        "TABLE",
        "PIVOT",
        "UNPIVOT",
        "SUMMARIZE",
        "DESCRIBE",
        "SHOW",
        "EXPLAIN",
    ];
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let mut depth = 0usize;
    let mut code = plan.tokens(0..sql.len()).filter(|token| !token.kind.is_trivia());
    let first = code.next()?;
    let word = |range: std::ops::Range<usize>| sql.get(range).map(str::to_ascii_uppercase);
    let first_word = match first.kind {
        ScriptTokenKind::Word => word(first.range)?,
        ScriptTokenKind::OpenParen => return Some("SELECT".to_owned()),
        _ => return None,
    };
    if first_word != "WITH" {
        return Some(first_word);
    }
    // A CTE may be named `update`, but its name follows WITH, RECURSIVE
    // or a comma, while the statement follows the last body's `)`.
    let mut after_body = false;
    for token in code {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => {
                depth = depth.saturating_sub(1);
                after_body = depth == 0;
                continue;
            }
            ScriptTokenKind::Word if depth == 0 && after_body => {
                let candidate = word(token.range)?;
                if VERBS.contains(&candidate.as_str()) {
                    return Some(candidate);
                }
            }
            _ => {}
        }
        if depth == 0 {
            after_body = false;
        }
    }
    None
}

/// Whether a statement of `sql` begins, ends or replaces a transaction.
/// A streamed read's own read-only transaction holds only while the
/// user's SQL leaves it alone.
pub(crate) fn controls_transaction(sql: &str) -> bool {
    split_statements(sql).into_iter().any(|statement| {
        words(statement).first().is_some_and(|first| {
            matches!(
                first.as_str(),
                "BEGIN" | "START" | "COMMIT" | "END" | "ROLLBACK" | "ABORT"
            )
        })
    })
}

/// The words an ATTACH may carry before its path.
const ATTACH_WORDS: [&str; 6] = ["DATABASE", "IF", "NOT", "EXISTS", "OR", "REPLACE"];

/// The source text of the path an ATTACH statement names: a string
/// constant in any of DuckDB's forms, which only an alias or the options
/// may follow.
fn attach_literal(statement: &str) -> Option<&str> {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(statement, grammar, LexicalSettings::default_for(grammar));
    let mut tokens = plan.tokens(0..statement.len()).filter(|token| !token.kind.is_trivia());
    let word = |token: &ScriptToken, words: &[&str]| {
        token.kind == ScriptTokenKind::Word
            && statement
                .get(token.range.clone())
                .is_some_and(|text| words.iter().any(|word| text.eq_ignore_ascii_case(word)))
    };
    let first = tokens.next()?;
    if !word(&first, &["ATTACH"]) {
        return None;
    }
    let start = tokens.find(|token| !word(token, &ATTACH_WORDS))?.range.start;
    let end = tokens
        .find(|token| token.kind == ScriptTokenKind::OpenParen || word(token, &["AS"]))
        .map_or(statement.len(), |token| token.range.start);
    statement.get(start..end).map(str::trim_end)
}

/// The files an ATTACH may open. DuckDB decodes the path itself, so its
/// escapes and continued strings read as DuckDB reads them, then it is
/// expanded the way DuckDB opens it. Both readings of a
/// `name:` prefix are kept, since a TYPE option leaves it in the name.
///
/// Text DuckDB cannot read as a string is no string constant, so DuckDB
/// refuses the ATTACH while parsing it and opens nothing.
fn attach_targets(link: &Link, literal: &str) -> Result<Vec<PathBuf>, DriverError> {
    // The path goes last, on a line of its own, so a comment after it
    // hides nothing.
    let read = link.connection.query_row(
        &format!("SELECT current_setting('home_directory'),\n{literal}\n"),
        [],
        |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, duckdb::types::Value>(1)?)),
    );
    let (home, path) = match read.map_err(map_error) {
        Ok((home, duckdb::types::Value::Text(path))) => (home, path),
        Ok(_) => return Ok(Vec::new()),
        Err(error) if is_parse_error(&error) => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let home = home
        .filter(|home| !home.is_empty())
        .map(OsString::from)
        .or_else(|| std::env::var_os("HOME"));
    let mut readings = vec![path.as_str()];
    if let Some(prefixed) = extension_prefix(&path) {
        readings.push(path.get(prefixed.len() + 1..).unwrap_or_default());
    }
    Ok(readings
        .into_iter()
        .filter(|path| !path.is_empty() && !path.starts_with(":memory:"))
        .map(|path| resolved_like_duckdb(expand_path(path, home.as_deref())))
        .collect())
}

/// The path as DuckDB opens it: made absolute, each part that is there
/// resolved with its links, and `..` taken by its text past one that is
/// not, so `d/missing/../a.duckdb` is `d/a.duckdb` and `link/../a.duckdb`
/// is beside where the link points.
fn resolved_like_duckdb(path: PathBuf) -> PathBuf {
    use std::path::Component;
    let absolute = match path.is_absolute() {
        true => path,
        false => std::env::current_dir().map_or(path.clone(), |directory| directory.join(&path)),
    };
    let mut resolved = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                resolved.pop();
            }
            other => {
                resolved.push(other);
                if let Ok(canonical) = std::fs::canonicalize(&resolved) {
                    resolved = canonical;
                }
            }
        }
    }
    resolved
}

/// Whether an ATTACH asks for a HIDDEN database, which DuckDB leaves out
/// of `duckdb_databases()`. Its options are the parenthesis after the
/// path, each a name, quoted or not, and an optional value; measured on
/// DuckDB 1.5, `HIDDEN false` attaches a listed database.
fn attach_hides(statement: &str) -> bool {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(statement, grammar, LexicalSettings::default_for(grammar));
    let tokens: Vec<(ScriptTokenKind, &str)> = plan
        .tokens(0..statement.len())
        .filter(|token| !token.kind.is_trivia())
        .map(|token| (token.kind, statement.get(token.range).unwrap_or_default()))
        .collect();
    let mut depth = 0usize;
    let mut option_starts = false;
    for (index, &(kind, text)) in tokens.iter().enumerate() {
        let is_option_name = option_starts;
        option_starts = false;
        match kind {
            ScriptTokenKind::OpenParen => {
                depth += 1;
                option_starts = depth == 1;
            }
            ScriptTokenKind::CloseParen => depth = depth.saturating_sub(1),
            ScriptTokenKind::Punct if depth == 1 && text == "," => option_starts = true,
            ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier if is_option_name => {
                let name = text
                    .strip_prefix('"')
                    .and_then(|name| name.strip_suffix('"'))
                    .unwrap_or(text);
                let turned_off = tokens.get(index + 1).is_some_and(|&(kind, value)| {
                    let value = match kind {
                        ScriptTokenKind::StringLiteral => value.trim_matches('\''),
                        _ => value,
                    };
                    value.eq_ignore_ascii_case("false") || value == "0"
                });
                if name.eq_ignore_ascii_case("hidden") && !turned_off {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

/// A `name:` before the path, which DuckDB reads as the engine that
/// opens it: at least two letters, digits or underscores, not a URL.
fn extension_prefix(path: &str) -> Option<&str> {
    let colon = path.find(':').filter(|colon| *colon >= 2)?;
    let prefix = path.get(..colon)?;
    let is_url = path.get(colon..colon + 3) == Some("://");
    let is_name = prefix.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_');
    (is_name && !is_url).then_some(prefix)
}

/// The path as DuckDB's file system opens it: a leading `~` is the home
/// directory, and a `file:` URL is the path it holds.
fn expand_path(path: &str, home: Option<&OsStr>) -> PathBuf {
    if let Some(rest) = path.strip_prefix('~') {
        let mut expanded = home.map(OsString::from).unwrap_or_default();
        expanded.push(rest);
        return PathBuf::from(expanded);
    }
    let url_offset = match path.strip_prefix("file:/") {
        None => 0,
        Some(rest) if !rest.starts_with('/') => 5,
        Some(rest) if rest.starts_with("//") => 7,
        Some(rest) if rest.get(1..).is_some_and(|host| host.starts_with("localhost/")) => 16,
        Some(_) => 0,
    };
    PathBuf::from(path.get(url_offset..).unwrap_or(path))
}

/// The words of `sql`, upper case, past comments and outside strings
/// and quoted names.
fn words(sql: &str) -> Vec<String> {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    plan.tokens(0..sql.len())
        .filter(|token| token.kind == ScriptTokenKind::Word)
        .filter_map(|token| sql.get(token.range))
        .map(str::to_ascii_uppercase)
        .collect()
}

/// The statements of a script, split where DuckDB's parser ends one.
///
/// An unterminated string, identifier or block comment runs to the end
/// of the text, and the statement it opens or continues goes to DuckDB as
/// it stands, so the error is DuckDB's own. Cutting an open comment off
/// would run what came before it: `DELETE FROM t /* where ...` would
/// empty the table.
pub(crate) fn split_statements(sql: &str) -> Vec<&str> {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let open_at = plan
        .diagnostics()
        .iter()
        .map(|ScriptDiagnostic::Unterminated { start, .. }| *start)
        .min();
    let Some(open_at) = open_at else {
        return plan.statements().iter().map(|statement| statement.text(sql)).collect();
    };
    let mut statements = Vec::with_capacity(plan.statements().len());
    let mut tail_start = open_at;
    for statement in plan.statements() {
        if statement.range.start >= open_at {
            break;
        }
        let ended = statement.range.end <= open_at
            && plan
                .tokens(statement.range.end..open_at)
                .any(|token| token.kind == ScriptTokenKind::Semicolon);
        if !ended {
            tail_start = statement.range.start;
            break;
        }
        statements.push(statement.text(sql));
    }
    let tail = sql.get(tail_start..).unwrap_or_default().trim_end();
    if !tail.is_empty() {
        statements.push(tail);
    }
    statements
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statements_split_as_duckdb_parses_them() {
        assert_eq!(
            split_statements("SELECT 1; SELECT $$a;b$$; /* c; */ SELECT 'd;e'"),
            ["SELECT 1", "SELECT $$a;b$$", "SELECT 'd;e'"]
        );
        assert_eq!(split_statements("SELECT 1; SELECT 'open"), ["SELECT 1", "SELECT 'open"]);
        assert_eq!(split_statements("SELECT 1; /* open"), ["SELECT 1", "/* open"]);
        assert_eq!(
            split_statements("SELECT 1; DELETE FROM t /* WHERE a = 1"),
            ["SELECT 1", "DELETE FROM t /* WHERE a = 1"]
        );
        assert_eq!(
            split_statements("DELETE FROM t -- why;\n/* open"),
            ["DELETE FROM t -- why;\n/* open"]
        );
        assert!(split_statements("  -- only a comment\n").is_empty());
    }

    #[test]
    fn a_cte_named_like_a_verb_is_not_the_statement() {
        assert_eq!(
            main_verb("WITH update AS (SELECT true AS \"Success\") SELECT * FROM update").as_deref(),
            Some("SELECT")
        );
        assert_eq!(
            main_verb("WITH RECURSIVE insert (n) AS (SELECT 1), delete AS MATERIALIZED (SELECT 2) DELETE FROM t")
                .as_deref(),
            Some("DELETE")
        );
        assert_eq!(
            main_verb("WITH src AS (SELECT 1 AS a) INSERT INTO t SELECT a FROM src").as_deref(),
            Some("INSERT")
        );
    }

    #[test]
    fn only_a_row_change_without_returning_reports_a_count() {
        assert!(changes_rows("INSERT INTO t VALUES (1)"));
        assert!(changes_rows("/* why */ update t SET a = 1"));
        assert!(changes_rows("COPY t FROM 'x.csv'"));
        assert!(!changes_rows("DELETE FROM t RETURNING *"));
        assert!(!changes_rows("SELECT 1 AS \"Count\""));
        assert!(!changes_rows("CREATE TABLE t (a INTEGER)"));
        assert!(changes_rows("INSERT INTO t VALUES ('returning')"));
        assert!(changes_rows(
            "WITH src AS (SELECT 1 AS a) INSERT INTO t SELECT a FROM src"
        ));
        assert!(!changes_rows("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x"));
        assert_eq!(
            main_verb("WITH RECURSIVE r AS (SELECT 1) SELECT * FROM r").as_deref(),
            Some("SELECT")
        );
        assert_eq!(main_verb("(SELECT 1)").as_deref(), Some("SELECT"));
    }

    #[test]
    fn an_attach_names_its_path_with_a_string_constant() {
        assert_eq!(
            attach_literal("ATTACH $db$/srv/b.db$db$ AS b"),
            Some("$db$/srv/b.db$db$")
        );
        assert_eq!(attach_literal(r"ATTACH E'\x2fsrv/c.db'"), Some(r"E'\x2fsrv/c.db'"));
        assert_eq!(
            attach_literal("/* x */ attach database if not exists 'it''s.db' (READ_ONLY)"),
            Some("'it''s.db'")
        );
        assert_eq!(
            attach_literal("ATTACH OR REPLACE U&'d\\0061ta.db' AS d"),
            Some("U&'d\\0061ta.db'")
        );
        assert_eq!(
            attach_literal("ATTACH '/srv/'\n-- more\n'a.db' AS a"),
            Some("'/srv/'\n-- more\n'a.db'")
        );
        assert_eq!(attach_literal("SELECT 'ATTACH x'"), None);
        assert_eq!(attach_literal("DETACH s"), None);
    }

    #[test]
    fn a_path_is_expanded_as_duckdb_opens_it() {
        let home = Some(OsStr::new("/home/ana"));

        assert_eq!(expand_path("~/a.db", home), PathBuf::from("/home/ana/a.db"));
        assert_eq!(expand_path("~a.db", home), PathBuf::from("/home/anaa.db"));
        assert_eq!(expand_path("file:///srv/a.db", home), PathBuf::from("/srv/a.db"));
        assert_eq!(
            expand_path("file://localhost/srv/a.db", home),
            PathBuf::from("/srv/a.db")
        );
        assert_eq!(expand_path("file:/srv/a.db", home), PathBuf::from("/srv/a.db"));
        assert_eq!(
            expand_path("file://host/srv/a.db", home),
            PathBuf::from("file://host/srv/a.db")
        );
        assert_eq!(expand_path("rel/a.db", home), PathBuf::from("rel/a.db"));
    }

    /// Measured against DuckDB 1.5: a missing part is passed by its text,
    /// a link is followed before the `..` after it.
    #[test]
    fn a_path_is_resolved_as_duckdb_opens_it() {
        let root = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(root.path()).unwrap();
        std::fs::create_dir_all(base.join("srv/sub")).unwrap();
        std::fs::create_dir(base.join("links")).unwrap();
        std::os::unix::fs::symlink(base.join("srv/sub"), base.join("links/sub")).unwrap();

        assert_eq!(
            resolved_like_duckdb(base.join("missing/../held.duckdb")),
            base.join("held.duckdb")
        );
        assert_eq!(
            resolved_like_duckdb(base.join("links/sub/../x.duckdb")),
            base.join("srv/x.duckdb")
        );
        assert_eq!(
            resolved_like_duckdb(base.join("./srv/./a.duckdb")),
            base.join("srv/a.duckdb")
        );
        assert!(resolved_like_duckdb(PathBuf::from("rel.duckdb")).is_absolute());
    }

    /// Measured against DuckDB 1.5: a quoted option name is read as the
    /// bare one, and `false` turns the option off.
    #[test]
    fn a_hidden_attach_is_told_by_its_options() {
        assert!(attach_hides("ATTACH 'a.duckdb' AS a (HIDDEN)"));
        assert!(attach_hides("ATTACH 'a.duckdb' (READ_ONLY, hidden true)"));
        assert!(attach_hides("ATTACH 'a.duckdb' AS a (\"hidden\")"));
        assert!(attach_hides("ATTACH 'a.duckdb' AS a (\"read_only\" false,hidden)"));
        assert!(!attach_hides("ATTACH 'a.duckdb' AS a (HIDDEN false)"));
        assert!(!attach_hides("ATTACH 'a.duckdb' AS a (TYPE duckdb, HIDDEN 0)"));
        assert!(!attach_hides("ATTACH 'a.duckdb' AS a (HIDDEN 'false')"));
        assert!(!attach_hides("ATTACH 'a.duckdb' AS hidden"));
        assert!(!attach_hides("ATTACH 'hidden.duckdb' AS a (READ_ONLY)"));
        assert!(!attach_hides("ATTACH 'a.duckdb' AS a (TYPE hidden)"));
    }

    #[test]
    fn an_engine_prefix_is_a_name_before_a_colon() {
        assert_eq!(extension_prefix("duckdb:/srv/a.db"), Some("duckdb"));
        assert_eq!(extension_prefix("sqlite:a.db"), Some("sqlite"));
        assert_eq!(extension_prefix("s3://bucket/a.db"), None);
        assert_eq!(extension_prefix("c:/a.db"), None);
        assert_eq!(extension_prefix("my file:a.db"), None);
        assert_eq!(extension_prefix("/srv/a.db"), None);
    }

    #[test]
    fn what_a_call_or_an_execute_returns_stays_rows() {
        let count = Shape {
            names: vec!["Count".to_owned()],
            types: vec![DuckType::Integer {
                width: tablepro_core::column::IntegerWidth::W64,
                signed: true,
            }],
        };

        assert_eq!(command_result("EXECUTE q", &count), None);
        assert_eq!(command_result("CALL counted()", &count), None);
        assert_eq!(
            command_result("INSERT INTO t VALUES (1)", &count),
            Some(Command::ChangedRows)
        );
    }

    #[test]
    fn transaction_control_is_found_in_any_statement() {
        assert!(controls_transaction("SELECT 1; COMMIT; DELETE FROM t"));
        assert!(controls_transaction("/* x */ begin transaction"));
        assert!(controls_transaction("SELECT 1; ABORT"));
        assert!(!controls_transaction("SELECT 'COMMIT'; SELECT \"end\" FROM t"));
        assert!(!controls_transaction("WITH x AS (SELECT 1) SELECT * FROM x"));
    }
}
