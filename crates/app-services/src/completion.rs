use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};

use tablepro_core::sql_syntax::script::LexicalSettings;
use tablepro_core::{Connection, OperationControl, sql_syntax::SqlGrammar};
use tokio_util::sync::CancellationToken;

use super::completion_identifiers::{bare_reference, split_table_reference, table_key, words};

pub const SQL_KEYWORDS: &str = "\
SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE \
JOIN INNER LEFT RIGHT FULL OUTER ON USING UNION INTERSECT EXCEPT \
GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT ALL AS WITH \
CREATE TABLE INDEX VIEW DROP ALTER TRUNCATE \
PRIMARY KEY FOREIGN REFERENCES UNIQUE NOT NULL DEFAULT CHECK \
AND OR IS LIKE IN BETWEEN EXISTS ANY \
COUNT SUM AVG MIN MAX CASE WHEN THEN ELSE END \
TRUE FALSE ASC DESC RETURNING";

#[derive(Default)]
pub struct SchemaIndex {
    tables: Vec<String>,
    table_keys: HashSet<String>,
    table_grammar: Option<SqlGrammar>,
    pub columns: HashMap<String, Vec<String>>,
    pub grammar: Option<SqlGrammar>,
    connection: Option<crate::connection_identity::ConnectionIdentity>,
    generation: u64,
    requests: ColumnRequests,
}

#[derive(Default)]
struct ColumnRequests {
    pending: HashSet<String>,
    cancellation: CancellationToken,
}

impl ColumnRequests {
    fn retire(&mut self) {
        self.pending.clear();
        self.cancellation.cancel();
        self.cancellation = CancellationToken::new();
    }
}

impl Drop for ColumnRequests {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}

impl std::fmt::Debug for SchemaIndex {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SchemaIndex")
            .field("tables", &self.tables)
            .field("columns", &self.columns)
            .field("generation", &self.generation)
            .finish()
    }
}

#[derive(Debug)]
pub struct SchemaRequest {
    pub generation: u64,
    pub table: String,
}

impl SchemaIndex {
    pub fn set_tables(&mut self, tables: Vec<String>) {
        self.table_keys.clear();
        self.table_grammar = self.grammar;
        for table in &tables {
            if let Some(key) = table_key(table, self.grammar) {
                self.table_keys.insert(bare_name(&key).to_string());
                self.table_keys.insert(key);
            }
        }
        self.tables = tables;
    }

    pub fn invalidate_columns(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.columns.clear();
        self.retire_column_requests();
    }

    pub fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.tables.clear();
        self.table_keys = HashSet::new();
        self.columns.clear();
        self.grammar = None;
        self.connection = None;
        self.retire_column_requests();
    }

    pub fn sync_connection(&mut self, connection: &crate::connection_identity::ConnectionIdentity) -> bool {
        let unchanged = self.connection.as_ref() == Some(connection);
        if unchanged {
            return false;
        }
        self.generation = self.generation.wrapping_add(1);
        self.connection = Some(connection.clone());
        self.tables.clear();
        self.table_keys = HashSet::new();
        self.columns.clear();
        self.retire_column_requests();
        true
    }

    pub fn request(&self, table: String) -> SchemaRequest {
        SchemaRequest {
            generation: self.generation,
            table,
        }
    }

    pub fn request_missing_columns(&mut self, tables: Vec<String>) -> Vec<SchemaRequest> {
        let mut requests = Vec::new();
        for table in tables {
            if !self.needs_columns(&table) {
                continue;
            }
            let Some(key) = table_key(&table, self.grammar) else {
                continue;
            };
            if self.requests.pending.insert(key) {
                requests.push(self.request(table));
            }
        }
        requests
    }

    pub fn column_request_token(&self) -> CancellationToken {
        self.requests.cancellation.clone()
    }

    pub fn complete_column_request(&mut self, request: &SchemaRequest, columns: Result<Vec<String>, ()>) -> bool {
        if !self.accepts(request) {
            return false;
        }
        let Some(key) = table_key(&request.table, self.grammar) else {
            return false;
        };
        if !self.requests.pending.contains(&key) {
            return false;
        }
        if let Ok(columns) = columns {
            self.columns.insert(key.clone(), columns);
        }
        self.requests.pending.remove(&key);
        true
    }

    pub fn complete_column_request_for_connection(
        &mut self,
        connection: &crate::connection_identity::ConnectionIdentity,
        request: &SchemaRequest,
        columns: Result<Vec<String>, ()>,
    ) -> bool {
        self.sync_connection(connection);
        self.complete_column_request(request, columns)
    }

    pub fn accepts(&self, request: &SchemaRequest) -> bool {
        request.generation == self.generation
    }

    pub fn columns_for(&self, table: &str) -> Option<&Vec<String>> {
        let key = table_key(table, self.grammar)?;
        if let Some(columns) = self.columns.get(&key) {
            return Some(columns);
        }
        if key.contains('\0') {
            return None;
        }
        let mut matches = self.columns.iter().filter(|(known, _)| bare_name(known) == key);
        let (_, columns) = matches.next()?;
        matches.next().is_none().then_some(columns)
    }

    pub fn knows_columns(&self, table: &str) -> bool {
        self.columns_for(table).is_some()
    }

    pub fn needs_columns(&self, table: &str) -> bool {
        let Some(key) = table_key(table, self.grammar) else {
            return false;
        };
        if self.knows_columns(table) {
            return false;
        }
        if self.table_grammar == self.grammar {
            return self.table_keys.contains(&key);
        }
        self.tables.iter().any(|known| {
            table_key(known, self.grammar)
                .is_some_and(|known| known == key || (!key.contains('\0') && bare_name(&known) == key))
        })
    }

    pub fn set_columns(&mut self, table: &str, columns: Vec<String>) {
        if let Some(key) = table_key(table, self.grammar) {
            self.columns.insert(key, columns);
        }
    }

    fn retire_column_requests(&mut self) {
        self.requests.retire();
    }
}

pub async fn fetch_column_names(
    connection: Arc<dyn Connection>,
    request: SchemaRequest,
    grammar: Option<SqlGrammar>,
    timeout_secs: u32,
    cancellation: CancellationToken,
) -> (SchemaRequest, Result<Vec<String>, ()>) {
    let Some((schema, table)) = split_table_reference(&request.table, grammar) else {
        return (request, Err(()));
    };
    let deadline =
        (timeout_secs > 0).then(|| tokio::time::Instant::now() + Duration::from_secs(u64::from(timeout_secs)));
    let control = OperationControl::new(cancellation, deadline);
    let columns = connection
        .fetch_columns_controlled(schema.as_deref(), &table, &control)
        .await
        .map(|columns| columns.into_iter().map(|column| column.name).collect())
        .map_err(|_| ());
    (request, columns)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    Tables,
    ColumnsOf(String),
    TablesAndColumns(Vec<String>),
}

fn bare_name(key: &str) -> &str {
    key.rsplit('\0').next().unwrap_or(key)
}

#[cfg(test)]
fn candidate_words(sql: &str, cursor_byte: usize, index: &SchemaIndex) -> Vec<String> {
    candidates(sql, cursor_byte, index, None, true, str::to_string)
}

pub(super) fn candidate_sql(
    sql: &str,
    cursor_byte: usize,
    index: &SchemaIndex,
    settings: Option<LexicalSettings>,
) -> Vec<String> {
    let driver = match index.grammar {
        Some(SqlGrammar::MySql) => "mysql",
        Some(SqlGrammar::MsSql) => "mssql",
        Some(SqlGrammar::ClickHouse) => "clickhouse",
        _ => "postgres",
    };
    candidates(sql, cursor_byte, index, settings, false, |column| {
        tablepro_core::sql_dialect::quote_ident(driver, column)
    })
}

pub(super) fn scope_at(sql: &str, cursor: usize, index: &SchemaIndex, settings: Option<LexicalSettings>) -> Scope {
    let statement = statement_around(sql, cursor, index.grammar, settings);
    scope_for(&statement.text[..statement.cursor], statement.text, index, settings)
}

fn candidates(
    sql: &str,
    cursor_byte: usize,
    index: &SchemaIndex,
    settings: Option<LexicalSettings>,
    bare_tables: bool,
    column_sql: impl Fn(&str) -> String,
) -> Vec<String> {
    let statement = statement_around(sql, cursor_byte, index.grammar, settings);
    let prefix = &statement.text[..statement.cursor];
    let scope = scope_for(prefix, statement.text, index, settings);
    let mut out: Vec<String> = Vec::new();

    match scope {
        Scope::ColumnsOf(table) => {
            if let Some(columns) = index.columns_for(&table) {
                out.extend(columns.iter().map(|column| column_sql(column)));
            }
        }
        Scope::Tables => {
            out.extend(index.tables.iter().cloned());
            if bare_tables {
                out.extend(bare_table_names(&index.tables, index.grammar));
            }
        }
        Scope::TablesAndColumns(tables) => {
            for table in &tables {
                if let Some(columns) = index.columns_for(table) {
                    out.extend(columns.iter().map(|column| column_sql(column)));
                }
            }
            if tables.is_empty() {
                for columns in index.columns.values() {
                    out.extend(columns.iter().map(|column| column_sql(column)));
                }
            }
            out.extend(index.tables.iter().cloned());
            if bare_tables {
                out.extend(bare_table_names(&index.tables, index.grammar));
            }
        }
    }

    out.sort_unstable();
    out.dedup();
    out
}

pub fn referenced_tables(sql: &str, cursor_byte: usize, grammar: Option<SqlGrammar>) -> Vec<String> {
    referenced_tables_with(sql, cursor_byte, grammar, None)
}

pub fn referenced_tables_with(
    sql: &str,
    cursor_byte: usize,
    grammar: Option<SqlGrammar>,
    settings: Option<LexicalSettings>,
) -> Vec<String> {
    let statement = statement_around(sql, cursor_byte, grammar, settings);
    table_references(statement.text, grammar, settings)
        .into_iter()
        .map(|(table, _)| table)
        .collect()
}

fn bare_table_names(tables: &[String], grammar: Option<SqlGrammar>) -> Vec<String> {
    tables
        .iter()
        .filter_map(|table| bare_reference(table, grammar))
        .collect()
}

struct StatementSpan<'a> {
    text: &'a str,
    cursor: usize,
}

fn statement_around(
    sql: &str,
    cursor_byte: usize,
    grammar: Option<SqlGrammar>,
    settings: Option<LexicalSettings>,
) -> StatementSpan<'_> {
    let cursor = floor_char_boundary(sql, cursor_byte.min(sql.len()));
    let range = grammar.map_or(0..sql.len(), |grammar| statement_range(sql, cursor, grammar, settings));
    StatementSpan {
        text: &sql[range.start..range.end],
        cursor: cursor - range.start,
    }
}

fn statement_range(
    sql: &str,
    cursor: usize,
    grammar: SqlGrammar,
    settings: Option<LexicalSettings>,
) -> std::ops::Range<usize> {
    let plan = super::completion_identifiers::plan_with(sql, Some(grammar), settings);
    let statements = plan.statements();
    let following = statements.partition_point(|statement| statement.range.start <= cursor);
    let next_end = statements
        .get(following)
        .map_or(sql.len(), |statement| statement.range.end);
    let Some(current) = following.checked_sub(1).and_then(|index| statements.get(index)) else {
        return 0..next_end;
    };
    let terminator_end = plan
        .tokens(current.range.end..current.extent.end)
        .filter(|token| !token.kind.is_trivia())
        .map(|token| token.range.end)
        .last();
    if let Some(terminator_end) = terminator_end.filter(|end| cursor >= *end) {
        return terminator_end..next_end;
    }
    current.range.start..current.range.end.max(cursor)
}

fn floor_char_boundary(text: &str, mut index: usize) -> usize {
    while index > 0 && !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn scope_for(prefix: &str, statement: &str, index: &SchemaIndex, settings: Option<LexicalSettings>) -> Scope {
    let references = table_references(statement, index.grammar, settings);
    let keyword = last_keyword(prefix, index.grammar, settings);
    let in_table_position = keyword
        .as_deref()
        .is_some_and(|keyword| TABLE_KEYWORDS.contains(&keyword));
    if let Some(qualifier) = trailing_qualifier(prefix, index.grammar, settings) {
        if in_table_position {
            return Scope::Tables;
        }
        let resolved = resolve_qualifier(&qualifier, &references, index.grammar);
        if index.knows_columns(&resolved) {
            return Scope::ColumnsOf(resolved);
        }
        return Scope::ColumnsOf(qualifier);
    }
    if in_table_position {
        return Scope::Tables;
    }
    Scope::TablesAndColumns(references.into_iter().map(|(table, _)| table).collect())
}

const TABLE_KEYWORDS: [&str; 6] = ["from", "join", "into", "update", "table", "truncate"];

pub(super) const KEYWORDS: [&str; 44] = [
    "select",
    "from",
    "where",
    "insert",
    "into",
    "values",
    "update",
    "set",
    "delete",
    "join",
    "inner",
    "left",
    "right",
    "full",
    "outer",
    "on",
    "using",
    "union",
    "intersect",
    "except",
    "group",
    "by",
    "order",
    "having",
    "limit",
    "offset",
    "distinct",
    "all",
    "as",
    "with",
    "create",
    "table",
    "index",
    "view",
    "drop",
    "alter",
    "truncate",
    "and",
    "or",
    "is",
    "like",
    "in",
    "between",
    "returning",
];

fn last_keyword(prefix: &str, grammar: Option<SqlGrammar>, settings: Option<LexicalSettings>) -> Option<String> {
    let mut last = None;
    for word in words(prefix, grammar, settings) {
        let lowered = word.to_ascii_lowercase();
        if KEYWORDS.contains(&lowered.as_str()) {
            last = Some(lowered);
        }
    }
    last
}

fn trailing_qualifier(prefix: &str, grammar: Option<SqlGrammar>, settings: Option<LexicalSettings>) -> Option<String> {
    if prefix.ends_with(char::is_whitespace) && !prefix.trim_end().ends_with('.') {
        return None;
    }
    let word = words(prefix, grammar, settings).last().copied()?;
    let plan = super::completion_identifiers::plan(word, Some(grammar.unwrap_or(SqlGrammar::Sqlite)));
    let dot = plan
        .tokens(0..word.len())
        .filter(|token| &word[token.range.clone()] == ".")
        .last()?;
    let qualifier = &word[..dot.range.start];
    table_key(qualifier, grammar)?;
    Some(qualifier.to_string())
}

fn resolve_qualifier(qualifier: &str, references: &[(String, Option<String>)], grammar: Option<SqlGrammar>) -> String {
    let Some(key) = table_key(qualifier, grammar) else {
        return qualifier.to_string();
    };
    for (table, alias) in references {
        if alias.as_ref().and_then(|alias| table_key(alias, grammar)).as_ref() == Some(&key) {
            return table.clone();
        }
    }
    for (table, _) in references {
        if table_key(table, grammar).is_some_and(|table| bare_name(&table) == key || table == key) {
            return table.clone();
        }
    }
    qualifier.to_string()
}

fn table_references(
    statement: &str,
    grammar: Option<SqlGrammar>,
    settings: Option<LexicalSettings>,
) -> Vec<(String, Option<String>)> {
    let tokens = words(statement, grammar, settings);
    let mut out: Vec<(String, Option<String>)> = Vec::new();
    let mut index = 0usize;
    while index < tokens.len() {
        let lowered = tokens[index].to_ascii_lowercase();
        let expects_table = matches!(lowered.as_str(), "from" | "join" | "update" | "into" | "truncate")
            || (lowered == "table" && index > 0 && tokens[index - 1].eq_ignore_ascii_case("alter"));
        if !expects_table {
            index += 1;
            continue;
        }
        let Some(table) = tokens.get(index + 1) else { break };
        if table_key(table, grammar).is_none() || KEYWORDS.contains(&table.to_ascii_lowercase().as_str()) {
            index += 1;
            continue;
        }
        let mut alias = None;
        let mut consumed = index + 2;
        if let Some(next) = tokens.get(consumed) {
            if next.eq_ignore_ascii_case("as") {
                alias = tokens.get(consumed + 1).map(ToString::to_string);
                consumed += 2;
            } else if !KEYWORDS.contains(&next.to_ascii_lowercase().as_str()) {
                alias = Some(next.to_string());
                consumed += 1;
            }
        }
        out.push((table.to_string(), alias));
        index = consumed;
    }
    out
}

#[cfg(test)]
mod tests;
