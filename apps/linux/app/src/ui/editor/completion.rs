use std::collections::HashMap;

use tablepro_core::sql_syntax::SqlGrammar;

#[derive(Default)]
pub struct SchemaIndex {
    pub tables: Vec<String>,
    pub columns: HashMap<String, Vec<String>>,
    pub grammar: Option<SqlGrammar>,
    connection: Option<crate::services::database_service::ConnectionIdentity>,
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
    pub fn sync_connection(&mut self, connection: &crate::services::database_service::ConnectionIdentity) -> bool {
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
        let key = table_key(table);
        if let Some(columns) = self.columns.get(&key) {
            return Some(columns);
        }
        if key.contains(KEY_SEPARATOR) {
            return None;
        }
        let mut matches = self.columns.iter().filter(|(known, _)| bare_name(known) == key);
        let (_, columns) = matches.next()?;
        matches.next().is_none().then_some(columns)
    }

    pub fn knows_columns(&self, table: &str) -> bool {
        self.columns_for(table).is_some()
    }

    pub fn set_columns(&mut self, table: &str, columns: Vec<String>) {
        self.columns.insert(table_key(table), columns);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    Tables,
    ColumnsOf(String),
    TablesAndColumns(Vec<String>),
}

const KEY_SEPARATOR: char = '\u{1f}';

pub struct ReferencePart {
    pub text: String,
    pub quoted: bool,
}

pub fn split_reference(reference: &str) -> Vec<ReferencePart> {
    let mut parts = Vec::new();
    let mut chars = reference.chars().peekable();
    loop {
        let mut text = String::new();
        let mut quoted = false;
        match chars.peek().copied() {
            Some(open @ ('"' | '`' | '[')) => {
                quoted = open == '"';
                let close = if open == '[' { ']' } else { open };
                chars.next();
                while let Some(c) = chars.next() {
                    if c == close && chars.peek() == Some(&close) {
                        chars.next();
                        text.push(close);
                    } else if c == close {
                        break;
                    } else {
                        text.push(c);
                    }
                }
            }
            _ => {
                while let Some(c) = chars.next_if(|c| *c != '.') {
                    text.push(c);
                }
            }
        }
        parts.push(ReferencePart { text, quoted });
        if chars.next().is_none() {
            return parts;
        }
    }
}

pub fn table_key(table: &str) -> String {
    split_reference(table)
        .into_iter()
        .map(|part| {
            if part.quoted {
                part.text
            } else {
                part.text.to_ascii_lowercase()
            }
        })
        .collect::<Vec<_>>()
        .join(&KEY_SEPARATOR.to_string())
}

fn bare_name(key: &str) -> &str {
    key.rsplit(KEY_SEPARATOR).next().unwrap_or(key)
}

pub fn candidate_words(sql: &str, cursor_byte: usize, index: &SchemaIndex) -> Vec<String> {
    let statement = statement_around(sql, cursor_byte, index.grammar);
    let prefix = &statement.text[..statement.cursor];
    let scope = scope_for(prefix, statement.text, index);
    let mut out: Vec<String> = Vec::new();

    match scope {
        Scope::ColumnsOf(table) => {
            if let Some(columns) = index.columns_for(&table) {
                out.extend(columns.iter().cloned());
            }
        }
        Scope::Tables => {
            out.extend(index.tables.iter().cloned());
            out.extend(bare_table_names(&index.tables));
        }
        Scope::TablesAndColumns(tables) => {
            for table in &tables {
                if let Some(columns) = index.columns_for(table) {
                    out.extend(columns.iter().cloned());
                }
            }
            if tables.is_empty() {
                for columns in index.columns.values() {
                    out.extend(columns.iter().cloned());
                }
            }
            out.extend(index.tables.iter().cloned());
            out.extend(bare_table_names(&index.tables));
        }
    }

    out.sort_unstable();
    out.dedup();
    out
}

pub fn referenced_tables(sql: &str, cursor_byte: usize, grammar: Option<SqlGrammar>) -> Vec<String> {
    let statement = statement_around(sql, cursor_byte, grammar);
    table_references(statement.text)
        .into_iter()
        .map(|(table, _)| table)
        .collect()
}

fn bare_table_names(tables: &[String]) -> Vec<String> {
    tables
        .iter()
        .filter_map(|table| table.rsplit('.').next())
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .collect()
}

struct StatementSpan<'a> {
    text: &'a str,
    cursor: usize,
}

fn statement_around(sql: &str, cursor_byte: usize, grammar: Option<SqlGrammar>) -> StatementSpan<'_> {
    let cursor = floor_char_boundary(sql, cursor_byte.min(sql.len()));
    let range = grammar.map_or(0..sql.len(), |grammar| statement_range(sql, cursor, grammar));
    StatementSpan {
        text: &sql[range.start..range.end],
        cursor: cursor - range.start,
    }
}

fn statement_range(sql: &str, cursor: usize, grammar: SqlGrammar) -> std::ops::Range<usize> {
    let plan = super::statement_cursor::plan_for(sql, grammar);
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

fn scope_for(prefix: &str, statement: &str, index: &SchemaIndex) -> Scope {
    let references = table_references(statement);
    let keyword = last_keyword(prefix);
    let in_table_position = keyword
        .as_deref()
        .is_some_and(|keyword| TABLE_KEYWORDS.contains(&keyword));
    if let Some(qualifier) = trailing_qualifier(prefix) {
        if in_table_position {
            return Scope::Tables;
        }
        let resolved = resolve_qualifier(&qualifier, &references);
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

const KEYWORDS: [&str; 44] = [
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

fn last_keyword(prefix: &str) -> Option<String> {
    let mut last = None;
    for word in words(prefix) {
        let lowered = word.to_ascii_lowercase();
        if KEYWORDS.contains(&lowered.as_str()) {
            last = Some(lowered);
        }
    }
    last
}

fn trailing_qualifier(prefix: &str) -> Option<String> {
    let trailing: String = prefix
        .chars()
        .rev()
        .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '.' || *c == '"')
        .collect::<Vec<char>>()
        .into_iter()
        .rev()
        .collect();
    let (qualifier, _) = trailing.rsplit_once('.')?;
    let qualifier = qualifier.rsplit('.').next().unwrap_or(qualifier);
    let cleaned = qualifier.trim_matches('"');
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

fn resolve_qualifier(qualifier: &str, references: &[(String, Option<String>)]) -> String {
    let lowered = qualifier.to_ascii_lowercase();
    for (table, alias) in references {
        if alias.as_deref().map(str::to_ascii_lowercase) == Some(lowered.clone()) {
            return table.clone();
        }
    }
    for (table, _) in references {
        if bare_name(&table_key(table)) == lowered {
            return table.clone();
        }
    }
    qualifier.to_string()
}

fn table_references(statement: &str) -> Vec<(String, Option<String>)> {
    let tokens: Vec<&str> = words(statement).collect();
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
        if KEYWORDS.contains(&table.to_ascii_lowercase().as_str()) {
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

fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '.' || c == '"'))
        .filter(|word| !word.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn table_key_keeps_the_schema_and_ignores_quoting_and_case() {
        assert_eq!(table_key("Public.Users"), table_key("public.users"));
        assert_eq!(table_key("`Orders`"), table_key("orders"));
        assert_eq!(table_key("[dbo].[Items]"), table_key("dbo.items"));
    }

    #[test]
    fn a_double_quoted_name_keeps_its_case_and_stays_distinct() {
        assert_ne!(table_key("public.\"Users\""), table_key("public.users"));
        assert_eq!(table_key("public.\"users\""), table_key("public.users"));
        assert_ne!(table_key("\"a.b\""), table_key("a.b"));
        assert_ne!(table_key("public.\"a\"\"b\""), table_key("public.ab"));
    }

    #[test]
    fn two_spellings_keep_their_own_columns() {
        let index = index_with(&[("public.users", &["id"]), ("public.\"Users\"", &["Id", "name"])]);
        assert_eq!(index.columns_for("public.users"), Some(&vec!["id".to_string()]));
        assert_eq!(
            index.columns_for("public.\"Users\""),
            Some(&vec!["Id".to_string(), "name".to_string()])
        );
    }

    #[test]
    fn a_reference_splits_on_dots_outside_quotes() {
        let texts = |reference: &str| {
            split_reference(reference)
                .into_iter()
                .map(|part| part.text)
                .collect::<Vec<_>>()
        };
        assert_eq!(texts("\"odd.schema\".\"a.b\""), ["odd.schema", "a.b"]);
        assert_eq!(texts("public.\"a\"\"b\""), ["public", "a\"b"]);
        assert_eq!(texts("[dbo].[Items]"), ["dbo", "Items"]);
        assert_eq!(texts("users."), ["users", ""]);
    }

    #[test]
    fn quoted_names_with_spaces_unicode_and_reserved_words_keep_their_identity() {
        let texts = |reference: &str| {
            split_reference(reference)
                .into_iter()
                .map(|part| part.text)
                .collect::<Vec<_>>()
        };
        assert_eq!(texts("\"my schema\".\"order items\""), ["my schema", "order items"]);
        assert_eq!(texts("\"café\".\"Таблица\""), ["café", "Таблица"]);
        assert_eq!(texts("public.\"select\""), ["public", "select"]);
        assert_ne!(table_key("public.\"Select\""), table_key("public.select"));
        assert_eq!(table_key("public.\"select\""), table_key("PUBLIC.SELECT"));
        assert_ne!(table_key("\"Café\""), table_key("café"));
    }

    #[test]
    fn invalid_neighbours_of_quoted_names_do_not_panic_or_merge() {
        let texts = |reference: &str| {
            split_reference(reference)
                .into_iter()
                .map(|part| part.text)
                .collect::<Vec<_>>()
        };
        assert_eq!(texts("\"unterminated"), ["unterminated"]);
        assert_eq!(texts("\"a\"\""), ["a\""]);
        assert_eq!(texts(""), [""]);
        assert_eq!(texts("."), ["", ""]);
        assert_ne!(table_key("\"a\".b"), table_key("\"a.b\""));
    }

    fn index_with(tables: &[(&str, &[&str])]) -> SchemaIndex {
        let mut index = SchemaIndex::default();
        for (table, columns) in tables {
            index.set_columns(table, columns.iter().map(|column| column.to_string()).collect());
        }
        index
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
