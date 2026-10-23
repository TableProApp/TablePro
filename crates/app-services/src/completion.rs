use std::collections::HashMap;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::LexicalSettings;

use super::completion_identifiers::{bare_reference, table_key, words};

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
    pub tables: Vec<String>,
    pub columns: HashMap<String, Vec<String>>,
    pub grammar: Option<SqlGrammar>,
    connection: Option<crate::connection_identity::ConnectionIdentity>,
    generation: u64,
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
    pub fn invalidate_columns(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.columns.clear();
    }

    pub fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.tables.clear();
        self.columns.clear();
        self.grammar = None;
        self.connection = None;
    }

    pub fn sync_connection(&mut self, connection: &crate::connection_identity::ConnectionIdentity) -> bool {
        let unchanged = self.connection.as_ref() == Some(connection);
        if unchanged {
            return false;
        }
        self.generation = self.generation.wrapping_add(1);
        self.connection = Some(connection.clone());
        self.tables.clear();
        self.columns.clear();
        true
    }

    pub fn request(&self, table: String) -> SchemaRequest {
        SchemaRequest {
            generation: self.generation,
            table,
        }
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
mod tests {
    use super::*;

    #[test]
    fn column_requests_require_a_complete_catalog_name() {
        let mut index = super::SchemaIndex {
            grammar: Some(tablepro_core::sql_syntax::SqlGrammar::PostgreSql),
            tables: vec![
                "public.customers".into(),
                "archive.customers".into(),
                "public.\"Users\"".into(),
            ],
            ..Default::default()
        };
        for partial in ["c", "cu", "customer", "public.customer", "missing.customers", "users"] {
            assert!(
                !index.needs_columns(partial),
                "unexpected catalog request for {partial}"
            );
        }
        for known in [
            "customers",
            "public.customers",
            "archive.customers",
            "\"Users\"",
            "public.\"Users\"",
        ] {
            assert!(index.needs_columns(known), "missing catalog request for {known}");
        }
        index.set_columns("public.customers", vec!["id".into()]);
        assert!(!index.needs_columns("public.customers"));
        assert!(index.needs_columns("archive.customers"));
    }

    fn index() -> SchemaIndex {
        let mut index = SchemaIndex {
            tables: vec!["public.users".into(), "public.orders".into()],
            ..SchemaIndex::default()
        };
        index.set_columns("public.users", vec!["id".into(), "email".into(), "created_at".into()]);
        index.set_columns("public.orders", vec!["id".into(), "user_id".into(), "total".into()]);
        index.grammar = Some(SqlGrammar::PostgreSql);
        index
    }

    #[test]
    fn a_semicolon_inside_a_line_comment_does_not_split_the_statement() {
        let words = candidates("SELECT * FROM public.users -- one; two\nWHERE |");
        assert!(words.contains(&"email".to_string()));
        assert!(!words.contains(&"total".to_string()));
    }

    #[test]
    fn a_semicolon_inside_a_block_comment_does_not_split_the_statement() {
        let words = candidates("SELECT * FROM public.users /* one; two */ WHERE |");
        assert!(words.contains(&"email".to_string()));
        assert!(!words.contains(&"total".to_string()));
    }

    #[test]
    fn a_semicolon_inside_a_dollar_quoted_body_does_not_split_the_statement() {
        let words = candidates("SELECT * FROM public.users WHERE email = $$a;b$$ AND |");
        assert!(words.contains(&"created_at".to_string()));
        assert!(!words.contains(&"total".to_string()));
    }

    #[test]
    fn a_cursor_after_the_last_semicolon_starts_a_new_statement() {
        let words = candidates("SELECT * FROM public.orders; SELECT * FROM |");
        assert!(words.contains(&"public.users".to_string()));
        assert!(!words.contains(&"total".to_string()));
    }

    #[test]
    fn schema_requests_are_accepted_only_by_their_generation() {
        let mut index = SchemaIndex::default();
        let current = index.request("users".into());
        index.generation = index.generation.wrapping_add(1);

        assert!(!index.accepts(&current));
        assert!(index.accepts(&index.request("users".into())));
    }

    fn candidates(sql: &str) -> Vec<String> {
        let cursor = sql.find('|').expect("cursor marker");
        let cleaned = sql.replace('|', "");
        candidate_words(&cleaned, cursor, &index())
    }

    #[test]
    fn after_from_only_tables_are_offered() {
        let words = candidates("SELECT * FROM |");
        assert!(words.contains(&"public.users".to_string()));
        assert!(words.contains(&"users".to_string()));
        assert!(!words.contains(&"email".to_string()));
    }

    #[test]
    fn after_a_table_alias_only_that_table_columns_are_offered() {
        let words = candidates("SELECT u.| FROM public.users AS u");
        assert_eq!(words, vec!["created_at".to_string(), "email".into(), "id".into()]);
    }

    #[test]
    fn an_alias_without_as_still_resolves() {
        let words = candidates("SELECT o.| FROM public.orders o");
        assert!(words.contains(&"total".to_string()));
        assert!(!words.contains(&"email".to_string()));
    }

    #[test]
    fn a_table_name_qualifier_resolves_without_an_alias() {
        let words = candidates("SELECT users.| FROM public.users");
        assert!(words.contains(&"email".to_string()));
        assert!(!words.contains(&"total".to_string()));
    }

    #[test]
    fn select_list_offers_columns_of_tables_named_later_in_the_statement() {
        let words = candidates("SELECT | FROM public.orders");
        assert!(words.contains(&"user_id".to_string()));
        assert!(!words.contains(&"email".to_string()));
    }

    #[test]
    fn where_clause_offers_columns_from_every_joined_table() {
        let words = candidates("SELECT * FROM public.users u JOIN public.orders o ON o.user_id = u.id WHERE |");
        assert!(words.contains(&"email".to_string()));
        assert!(words.contains(&"total".to_string()));
    }

    #[test]
    fn an_unknown_qualifier_offers_nothing_rather_than_every_column() {
        let words = candidates("SELECT nope.| FROM public.users");
        assert!(words.is_empty());
    }

    #[test]
    fn the_statement_under_the_cursor_decides_the_scope() {
        let words = candidates("SELECT * FROM public.users; SELECT | FROM public.orders");
        assert!(words.contains(&"total".to_string()));
        assert!(!words.contains(&"email".to_string()));
    }

    #[test]
    fn a_semicolon_inside_a_literal_does_not_split_the_statement() {
        let words = candidates("SELECT ';' , | FROM public.orders");
        assert!(words.contains(&"total".to_string()));
    }

    #[test]
    fn update_offers_tables_then_columns_for_set() {
        let tables = candidates("UPDATE |");
        assert!(tables.contains(&"public.orders".to_string()));
        let columns = candidates("UPDATE public.orders SET |");
        assert!(columns.contains(&"total".to_string()));
    }

    #[test]
    fn referenced_tables_reports_what_needs_columns() {
        let sql = "SELECT * FROM public.users u JOIN orders o ON o.user_id = u.id";
        assert_eq!(
            referenced_tables(sql, sql.len(), Some(SqlGrammar::PostgreSql)),
            vec!["public.users".to_string(), "orders".into()]
        );
    }

    #[test]
    fn a_schema_qualifier_in_table_position_offers_tables() {
        let words = candidates("SELECT * FROM public.|");
        assert!(words.contains(&"public.users".to_string()));
        assert!(!words.contains(&"email".to_string()));
    }

    #[test]
    fn a_cursor_past_the_end_is_clamped() {
        let sql = "SELECT * FROM public.users";
        let words = candidate_words(sql, sql.len() + 50, &index());
        assert!(words.contains(&"public.users".to_string()));
    }

    #[test]
    fn multibyte_text_before_the_cursor_does_not_panic() {
        let sql = "SELECT 'héllo→', ";
        let words = candidate_words(sql, sql.len(), &index());
        assert!(!words.is_empty());
    }

    #[test]
    fn quoted_aliases_and_whitespace_around_dots_keep_identity() {
        let mut index = index();
        index.set_columns(r#""odd.schema"."a.b""#, vec!["exact_column".into()]);
        for (prefix, tail) in [
            (r#"SELECT "Case Alias"."#, r#" FROM "odd.schema"."a.b" AS "Case Alias""#),
            ("SELECT x.", r#" FROM "odd.schema" . "a.b" AS x"#),
            (r#"SELECT "odd.schema"."a.b"."#, r#" FROM "odd.schema"."a.b""#),
        ] {
            let sql = format!("{prefix}{tail}");
            assert_eq!(candidate_words(&sql, prefix.len(), &index), vec!["exact_column"]);
        }
    }

    #[test]
    fn postgres_quoted_relations_keep_distinct_columns_and_aliases() {
        let mut index = index();
        index.set_columns("public.\"Users\"", vec!["quoted_only".into()]);
        assert_eq!(
            index.columns_for("public.users").unwrap(),
            &vec!["id", "email", "created_at"]
        );
        assert_eq!(index.columns_for("public.\"Users\"").unwrap(), &vec!["quoted_only"]);
        let sql = "SELECT u. FROM public.\"Users\" AS u";
        assert_eq!(candidate_words(sql, "SELECT u.".len(), &index), vec!["quoted_only"]);
    }

    #[test]
    fn postgres_quoted_dots_and_spaces_keep_complete_table_references() {
        let mut index = index();
        for name in [r#""odd.schema"."a.b""#, r#"public."a""b""#, r#"public."with space""#] {
            index.set_columns(name, vec!["exact_column".into()]);
            let sql = format!("SELECT x. FROM {name} AS x");
            assert_eq!(referenced_tables(&sql, sql.len(), index.grammar), vec![name]);
            assert_eq!(candidate_words(&sql, "SELECT x.".len(), &index), vec!["exact_column"]);
        }
    }

    #[test]
    fn table_key_keeps_the_schema_and_ignores_quoting_and_case() {
        assert_eq!(
            table_key("public.\"Users\"", Some(SqlGrammar::Sqlite)).as_deref(),
            Some("public\0users")
        );
        assert_eq!(
            table_key("`orders`", Some(SqlGrammar::MySql)).as_deref(),
            Some("orders")
        );
        assert_eq!(
            table_key("[dbo].[Items]", Some(SqlGrammar::MsSql)).as_deref(),
            Some("dbo\0items")
        );
    }

    #[test]
    fn a_double_quoted_name_keeps_its_case_and_stays_distinct() {
        let grammar = Some(SqlGrammar::PostgreSql);
        assert_ne!(
            table_key("public.\"Users\"", grammar),
            table_key("public.users", grammar)
        );
        assert_eq!(
            table_key("public.\"users\"", grammar),
            table_key("public.users", grammar)
        );
        assert_ne!(table_key("\"a.b\"", grammar), table_key("a.b", grammar));
        assert_ne!(table_key("public.\"a\"\"b\"", grammar), table_key("public.ab", grammar));
    }

    #[test]
    fn two_spellings_keep_their_own_columns() {
        let mut index = SchemaIndex {
            grammar: Some(SqlGrammar::PostgreSql),
            ..SchemaIndex::default()
        };
        index.set_columns("public.users", vec!["id".into()]);
        index.set_columns("public.\"Users\"", vec!["Id".into(), "name".into()]);
        assert_eq!(index.columns_for("public.users"), Some(&vec!["id".to_string()]));
        assert_eq!(
            index.columns_for("public.\"Users\""),
            Some(&vec!["Id".to_string(), "name".to_string()])
        );
    }

    #[test]
    fn a_reference_splits_on_dots_outside_quotes() {
        use super::super::completion_identifiers::split_table_reference;
        let grammar = Some(SqlGrammar::PostgreSql);
        assert_eq!(
            split_table_reference(r#""odd.schema"."a.b""#, grammar),
            Some((Some("odd.schema".into()), "a.b".into()))
        );
        assert_eq!(
            split_table_reference(r#"public."a""b""#, grammar),
            Some((Some("public".into()), "a\"b".into()))
        );
    }

    #[test]
    fn quoted_names_with_spaces_unicode_and_reserved_words_keep_their_identity() {
        use super::super::completion_identifiers::split_table_reference;
        let grammar = Some(SqlGrammar::PostgreSql);
        for (reference, schema, table) in [
            (r#""my schema"."order items""#, "my schema", "order items"),
            (r#""café"."Таблица""#, "café", "Таблица"),
            (r#"public."select""#, "public", "select"),
        ] {
            assert_eq!(
                split_table_reference(reference, grammar),
                Some((Some(schema.into()), table.into()))
            );
        }
        assert_ne!(
            table_key(r#"public."Select""#, grammar),
            table_key("public.select", grammar)
        );
        assert_eq!(
            table_key(r#"public."select""#, grammar),
            table_key("PUBLIC.SELECT", grammar)
        );
        assert_ne!(table_key(r#""Café""#, grammar), table_key("café", grammar));
    }

    #[test]
    fn invalid_neighbours_of_quoted_names_do_not_panic_or_merge() {
        let grammar = Some(SqlGrammar::PostgreSql);
        for invalid in [r#""unterminated"#, r#""a"""#, "", "."] {
            assert!(table_key(invalid, grammar).is_none());
        }
        assert_ne!(table_key(r#""a".b"#, grammar), table_key(r#""a.b""#, grammar));
    }

    fn index_with(tables: &[(&str, &[&str])]) -> SchemaIndex {
        let mut index = SchemaIndex::default();
        for (table, columns) in tables {
            index.set_columns(table, columns.iter().map(|column| column.to_string()).collect());
        }
        index
    }

    #[test]
    fn clearing_connection_metadata_removes_cached_candidates_and_retires_requests() {
        let mut index = SchemaIndex {
            grammar: Some(SqlGrammar::PostgreSql),
            ..SchemaIndex::default()
        };
        index.tables.push("public.safety_items".into());
        index.set_columns("public.safety_items", vec!["note".into()]);
        let request = index.request("public.safety_items".into());
        assert!(
            super::candidates("SELECT * FROM ", 14, &index, None, false, str::to_string)
                .iter()
                .any(|candidate| candidate == "public.safety_items")
        );

        index.clear();

        assert!(index.tables.is_empty());
        assert!(index.columns.is_empty());
        assert_eq!(index.grammar, None);
        assert!(!index.accepts(&request));
        let keyword_candidates = super::super::completion_proposals::candidates("SEL", 3, &index);
        assert!(
            keyword_candidates
                .values
                .iter()
                .any(|(label, value)| label == "SELECT" && value == "SELECT")
        );
        assert!(
            !super::candidates("SELECT * FROM ", 14, &index, None, false, str::to_string)
                .iter()
                .any(|candidate| candidate == "public.safety_items")
        );
    }

    #[test]
    fn same_named_tables_in_two_schemas_keep_separate_columns() {
        let index = index_with(&[("a.items", &["a_id"]), ("b.items", &["b_id"])]);
        assert_eq!(index.columns_for("a.items"), Some(&vec!["a_id".to_string()]));
        assert_eq!(index.columns_for("B.Items"), Some(&vec!["b_id".to_string()]));
    }

    #[test]
    fn an_unqualified_name_that_matches_two_schemas_offers_no_columns() {
        let index = index_with(&[("a.items", &["a_id"]), ("b.items", &["b_id"])]);
        assert_eq!(index.columns_for("items"), None);
        assert!(!index.knows_columns("items"));
    }

    #[test]
    fn an_unqualified_name_resolves_when_only_one_schema_has_it() {
        let index = index_with(&[("a.items", &["a_id"]), ("a.orders", &["o_id"])]);
        assert_eq!(index.columns_for("items"), Some(&vec!["a_id".to_string()]));
        assert!(index.knows_columns("Items"));
    }
}
