use std::collections::HashSet;
use std::sync::Arc;

use tablepro_core::dialect::{DatabaseLayout, SqlDialect};
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::completion::{
    CatalogAnswer, CatalogHome, CompletionScope, Ranked, Ranking, analyze, casefold, matched_runs, word_start,
};
use tablepro_core::sql_syntax::format::{format_selection, format_with_caret};
use tablepro_core::sql_syntax::script::LexicalSettings;

use crate::catalog::TableName;
use crate::statement_at::byte_at_unit;
use crate::syntax::{SqlGrammarTag, Utf16Offsets};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CompletionKindTag {
    Keyword,
    Schema,
    Table,
    View,
    MaterializedView,
    Column,
    Function,
}

// UTF-16 units of the label.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MatchedSpan {
    pub start: u32,
    pub length: u32,
}

// Label and insert text are cased for the word ranked: a keyword follows the case the user types keywords in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CompletionItem {
    pub label: String,
    pub insert_text: String,
    pub kind: CompletionKindTag,
    pub data_type: Option<String>,
    pub table: Option<TableName>,
    pub matched: Vec<MatchedSpan>,
}

// `total` counts every match; `items` holds the closest of them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CompletionPage {
    pub total: u32,
    pub items: Vec<CompletionItem>,
}

// The caret counts UTF-16 units.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FormattedSql {
    pub text: String,
    pub caret: u32,
}

// What one completion offers, ranked again for each word typed without reading the catalog again.
#[derive(Debug, uniffi::Object)]
pub struct CompletionList {
    candidates: Arc<[Candidate]>,
    word_start: u32,
    word: String,
}

#[uniffi::export]
impl CompletionList {
    // In UTF-16 units of the text the completion was asked for.
    pub fn word_start(&self) -> u32 {
        self.word_start
    }

    pub fn word(&self) -> String {
        self.word.clone()
    }

    // The closest `limit` matches for `word`, and how many matched in all.
    pub fn rank(&self, word: String, limit: u32) -> CompletionPage {
        let ranking = Ranking::new(self.candidates.clone(), &casefold(&word));
        let items = ranking
            .ranked()
            .iter()
            .take(usize::try_from(limit).unwrap_or(usize::MAX))
            .filter_map(|&at| self.candidates.get(usize::try_from(at).ok()?))
            .map(|candidate| candidate.item(&word, ranking.needle()))
            .collect();
        CompletionPage {
            total: u32::try_from(ranking.ranked().len()).unwrap_or(u32::MAX),
            items,
        }
    }
}

// The editor's own proposal; Linux keeps its own, with its snippets, until it moves onto these.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ProposalKind {
    Keyword,
    Schema,
    Table,
    View,
    MaterializedView,
    Column { data_type: String, table: TableRef },
    Function,
}

impl ProposalKind {
    // A sequence, a trigger or a key is never named on its own in a statement.
    fn for_object(kind: ObjectKind) -> Option<Self> {
        match kind {
            ObjectKind::Table | ObjectKind::PartitionedTable | ObjectKind::ForeignTable | ObjectKind::Dictionary => {
                Some(Self::Table)
            }
            ObjectKind::View => Some(Self::View),
            ObjectKind::MaterializedView => Some(Self::MaterializedView),
            ObjectKind::Function | ObjectKind::Procedure => Some(Self::Function),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Candidate {
    kind: ProposalKind,
    label: String,
    insert_text: String,
}

impl Ranked for Candidate {
    fn label(&self) -> &str {
        &self.label
    }

    fn kind_rank(&self) -> u8 {
        match self.kind {
            ProposalKind::Column { .. } => 0,
            ProposalKind::Table | ProposalKind::View | ProposalKind::MaterializedView => 1,
            ProposalKind::Schema => 2,
            ProposalKind::Function => 3,
            ProposalKind::Keyword => 5,
        }
    }
}

impl Candidate {
    fn new(kind: ProposalKind, label: &str, insert_text: String) -> Self {
        Self {
            kind,
            label: label.to_owned(),
            insert_text,
        }
    }

    fn keyword(keyword: &str) -> Self {
        Self::new(ProposalKind::Keyword, keyword, keyword.to_owned())
    }

    // A keyword goes in lower case once the word typed is all lower case, and as listed otherwise; a name keeps the
    // case the catalog has.
    fn cased(&self, text: &str, word: &str) -> String {
        let lowercase = word.chars().any(char::is_lowercase) && !word.chars().any(char::is_uppercase);
        if self.kind == ProposalKind::Keyword && lowercase {
            text.to_lowercase()
        } else {
            text.to_owned()
        }
    }

    fn item(&self, word: &str, needle: &str) -> CompletionItem {
        let label = self.cased(&self.label, word);
        let mut units = Utf16Offsets::new(&label);
        let matched = matched_runs(&label, needle)
            .into_iter()
            .filter_map(|run| {
                let start = units.at(run.start);
                let end = units.at(run.end);
                Some(MatchedSpan {
                    start: u32::try_from(start).ok()?,
                    length: u32::try_from(end - start).ok()?,
                })
            })
            .collect();
        let (kind, data_type, table) = match &self.kind {
            ProposalKind::Column { data_type, table } => (
                CompletionKindTag::Column,
                Some(data_type.clone()),
                Some(TableName {
                    schema: table.schema.clone(),
                    name: table.name.clone(),
                }),
            ),
            ProposalKind::Keyword => (CompletionKindTag::Keyword, None, None),
            ProposalKind::Schema => (CompletionKindTag::Schema, None, None),
            ProposalKind::Table => (CompletionKindTag::Table, None, None),
            ProposalKind::View => (CompletionKindTag::View, None, None),
            ProposalKind::MaterializedView => (CompletionKindTag::MaterializedView, None, None),
            ProposalKind::Function => (CompletionKindTag::Function, None, None),
        };
        CompletionItem {
            insert_text: self.cased(&self.insert_text, word),
            label,
            kind,
            data_type,
            table,
            matched,
        }
    }
}

// What the text before the caret asks for, read before the catalog is.
pub(crate) struct CompletionRequest {
    pub(crate) scope: CompletionScope,
    word_start: u32,
    word: String,
}

impl CompletionRequest {
    // None where nothing completes, and where nothing is typed yet in a place that takes anything, unless asked.
    pub(crate) fn new(text: &str, caret: u32, grammar: SqlGrammar, asked: bool) -> Option<Self> {
        if !grammar.is_sql() {
            return None;
        }
        let caret = byte_at_unit(text, usize::try_from(caret).ok()?);
        let start = word_start(text, caret);
        let scope = analyze(text, start, grammar, LexicalSettings::default_for(grammar))?;
        let word = text.get(start..caret).unwrap_or_default().to_owned();
        if word.is_empty() && !asked && !scope.names_a_place() {
            return None;
        }
        Some(Self {
            scope,
            word_start: u32::try_from(Utf16Offsets::new(text).at(start)).ok()?,
            word,
        })
    }

    pub(crate) fn list(
        self,
        answer: &CatalogAnswer,
        grammar: SqlGrammar,
        dialect: Option<&dyn SqlDialect>,
    ) -> CompletionList {
        CompletionList {
            candidates: candidates(&self.scope, answer, grammar, dialect).into(),
            word_start: self.word_start,
            word: self.word,
        }
    }
}

// Where unqualified names resolve for an editor in `database`: the connection's own, or the schema the catalog lists
// the database as, or nowhere the catalog describes.
pub(crate) fn catalog_home(layout: Option<DatabaseLayout>, own: Option<&str>, database: Option<&str>) -> CatalogHome {
    match database.filter(|name| !name.is_empty()) {
        None => CatalogHome::Connection,
        Some(name) if Some(name) == own => CatalogHome::Connection,
        Some(name) if layout == Some(DatabaseLayout::AsSchemas) => CatalogHome::Schema(name.to_owned()),
        Some(name) => CatalogHome::Elsewhere(name.to_owned()),
    }
}

// In the catalog's order. A name goes in quoted only where it would read as something else bare.
fn candidates(
    scope: &CompletionScope,
    answer: &CatalogAnswer,
    grammar: SqlGrammar,
    dialect: Option<&dyn SqlDialect>,
) -> Vec<Candidate> {
    let identifier = |name: &str| match dialect {
        Some(dialect) if !grammar.is_bare_identifier(name) => dialect.quote_identifier(name),
        _ => name.to_owned(),
    };
    let mut proposals = Vec::new();
    let mut columns: HashSet<&str> = HashSet::new();
    for (table, list) in &answer.columns {
        for column in list.iter() {
            // The same name in two joined tables is one thing to type.
            if !columns.insert(&column.name) {
                continue;
            }
            let kind = ProposalKind::Column {
                data_type: column.column_type.name.clone(),
                table: table.clone(),
            };
            proposals.push(Candidate::new(kind, &column.name, identifier(&column.name)));
        }
    }
    if matches!(scope, CompletionScope::Objects { schema: None }) {
        for schema in answer.schemas.iter().flat_map(|schemas| schemas.iter()) {
            if !schema.is_system {
                proposals.push(Candidate::new(
                    ProposalKind::Schema,
                    &schema.name,
                    identifier(&schema.name),
                ));
            }
        }
    }
    let general = matches!(scope, CompletionScope::General { .. });
    for object in answer.objects.iter().flat_map(|objects| objects.iter()) {
        if let Some(kind) = object_kind(object, general) {
            proposals.push(Candidate::new(kind, &object.name, identifier(&object.name)));
        }
    }
    if general {
        proposals.extend(grammar.keywords().map(Candidate::keyword));
    }
    proposals
}

// A relation anywhere a table goes; a function only where an expression can.
fn object_kind(object: &ObjectInfo, general: bool) -> Option<ProposalKind> {
    let kind = ProposalKind::for_object(object.kind)?;
    (kind != ProposalKind::Function || general).then_some(kind)
}

// A format changes only blanks, so the caret, in UTF-16 units, keeps the characters around it. A language that is not
// SQL comes back as it is.
#[uniffi::export]
pub fn format_sql(text: String, grammar: SqlGrammarTag, caret: u32) -> FormattedSql {
    let grammar = SqlGrammar::from(grammar);
    let caret = byte_at_unit(&text, usize::try_from(caret).unwrap_or(usize::MAX));
    let (formatted, caret) = if grammar.is_sql() {
        format_with_caret(&text, grammar, LexicalSettings::default_for(grammar), caret)
    } else {
        (text, caret)
    };
    let caret = Utf16Offsets::new(&formatted).at(caret);
    FormattedSql {
        caret: u32::try_from(caret).unwrap_or(u32::MAX),
        text: formatted,
    }
}

// The text between UTF-16 units `start` and `end` formatted, or as it is where the whole text would read differently.
#[uniffi::export]
pub fn format_sql_selection(text: String, grammar: SqlGrammarTag, start: u32, end: u32) -> String {
    let grammar = SqlGrammar::from(grammar);
    let start = byte_at_unit(&text, usize::try_from(start).unwrap_or(usize::MAX));
    let end = byte_at_unit(&text, usize::try_from(end).unwrap_or(usize::MAX)).max(start);
    if grammar.is_sql() {
        format_selection(&text, grammar, LexicalSettings::default_for(grammar), start..end)
    } else {
        text.get(start..end).unwrap_or_default().to_owned()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ColumnInfo;
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::meta::SchemaInfo;

    use super::*;

    fn request(marked: &str, asked: bool) -> Option<CompletionRequest> {
        let caret = marked.find('|').expect("a caret mark");
        let text = marked.replacen('|', "", 1);
        let units = u32::try_from(text[..caret].encode_utf16().count()).expect("a short text");
        CompletionRequest::new(&text, units, SqlGrammar::PostgreSql, asked)
    }

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
            parent_table: None,
        }
    }

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("integer"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn answer() -> CatalogAnswer {
        CatalogAnswer {
            schemas: Some(Arc::from([
                SchemaInfo {
                    name: "sales".to_owned(),
                    is_default: false,
                    is_system: false,
                },
                SchemaInfo {
                    name: "pg_catalog".to_owned(),
                    is_default: false,
                    is_system: true,
                },
            ])),
            objects: Some(Arc::from([
                object("users", ObjectKind::Table),
                object("Order Items", ObjectKind::View),
                object("refresh", ObjectKind::Function),
                object("ids", ObjectKind::Sequence),
            ])),
            columns: vec![
                (
                    TableRef::unqualified("users"),
                    Arc::from([column("id"), column("name")]),
                ),
                (
                    TableRef::unqualified("orders"),
                    Arc::from([column("id"), column("total")]),
                ),
            ],
        }
    }

    fn labels(candidates: &[Candidate]) -> Vec<&str> {
        candidates.iter().map(|candidate| candidate.label.as_str()).collect()
    }

    fn list(candidates: Vec<Candidate>) -> CompletionList {
        CompletionList {
            candidates: candidates.into(),
            word_start: 0,
            word: String::new(),
        }
    }

    #[test]
    fn a_place_that_takes_anything_waits_for_a_letter_unless_asked() {
        assert!(request("SELECT |", false).is_none());
        assert!(request("SELECT |", true).is_some());
        assert!(request("SELECT * FROM |", false).is_some());
        assert!(request("SELECT 's|'", true).is_none(), "a string completes nothing");
    }

    #[test]
    fn the_word_start_counts_utf16_units() {
        let found = request("SELECT '😀', đơn|", false).expect("a request");

        assert_eq!(found.word, "đơn");
        assert_eq!(found.word_start, 13);
    }

    #[test]
    fn a_decomposed_name_is_one_word() {
        let found = request("SELECT * FROM cafe\u{301}|", true).expect("a request");

        assert_eq!(found.word_start, 14);
        assert_eq!(found.word, "cafe\u{301}");
    }

    #[test]
    fn a_language_that_is_not_sql_completes_nothing() {
        assert!(CompletionRequest::new("GET k", 5, SqlGrammar::Redis, true).is_none());
    }

    #[test]
    fn a_table_place_offers_relations_and_user_schemas_quoting_where_a_bare_name_would_not_read() {
        let dialect = tablepro_test_support::FakeDialect;

        let found = candidates(
            &CompletionScope::Objects { schema: None },
            &answer(),
            SqlGrammar::PostgreSql,
            Some(&dialect),
        );

        assert_eq!(labels(&found), ["id", "name", "total", "sales", "users", "Order Items"]);
        let view = found.iter().find(|candidate| candidate.label == "Order Items");
        assert_eq!(view.map(|view| view.insert_text.as_str()), Some("\"Order Items\""));
    }

    #[test]
    fn anywhere_else_offers_functions_and_keywords_but_no_schemas_or_sequences() {
        let found = candidates(
            &CompletionScope::General {
                tables_in_statement: Vec::new(),
            },
            &answer(),
            SqlGrammar::PostgreSql,
            None,
        );

        let labels = labels(&found);
        assert!(labels.contains(&"refresh"));
        assert!(labels.contains(&"SELECT"));
        assert!(!labels.contains(&"sales"));
        assert!(!labels.contains(&"ids"));
    }

    #[test]
    fn a_keyword_follows_the_case_typed_and_a_name_keeps_its_own() {
        let words = list(vec![
            Candidate::keyword("SELECT"),
            Candidate::keyword("DELETE"),
            Candidate::new(ProposalKind::Table, "Selections", "\"Selections\"".to_owned()),
        ]);

        let lower = words.rank("sel".to_owned(), 10);
        let upper = words.rank("SEL".to_owned(), 10);

        assert_eq!(lower.total, 2);
        let first = lower.items.first().expect("a match");
        assert_eq!(
            (first.label.as_str(), first.insert_text.as_str(), first.kind),
            ("select", "select", CompletionKindTag::Keyword)
        );
        assert_eq!(first.matched, [MatchedSpan { start: 0, length: 3 }]);
        assert_eq!(
            upper.items.first().map(|item| item.insert_text.as_str()),
            Some("SELECT")
        );
        let table = lower.items.iter().find(|item| item.kind == CompletionKindTag::Table);
        assert_eq!(table.map(|item| item.insert_text.as_str()), Some("\"Selections\""));
        assert_eq!(words.rank("sel".to_owned(), 1).items.len(), 1);
    }

    #[test]
    fn a_column_carries_its_type_and_table() {
        let columns = list(vec![Candidate::new(
            ProposalKind::Column {
                data_type: "integer".to_owned(),
                table: TableRef::new(Some("public".to_owned()), "users"),
            },
            "id",
            "id".to_owned(),
        )]);

        let item = columns
            .rank(String::new(), 10)
            .items
            .into_iter()
            .next()
            .expect("the column");

        assert_eq!(item.kind, CompletionKindTag::Column);
        assert_eq!(item.data_type.as_deref(), Some("integer"));
        assert_eq!(
            item.table,
            Some(TableName {
                schema: Some("public".to_owned()),
                name: "users".to_owned()
            })
        );
    }

    #[test]
    fn a_tab_in_another_database_reads_names_where_the_catalog_lists_it() {
        assert_eq!(
            catalog_home(Some(DatabaseLayout::AsSchemas), Some("shop"), None),
            CatalogHome::Connection
        );
        assert_eq!(
            catalog_home(Some(DatabaseLayout::AsSchemas), Some("shop"), Some("shop")),
            CatalogHome::Connection
        );
        assert_eq!(
            catalog_home(Some(DatabaseLayout::AsSchemas), Some("shop"), Some("analytics")),
            CatalogHome::Schema("analytics".to_owned())
        );
        assert_eq!(
            catalog_home(Some(DatabaseLayout::WithSchemas), Some("shop"), Some("analytics")),
            CatalogHome::Elsewhere("analytics".to_owned())
        );
    }

    #[test]
    fn a_format_keeps_the_caret_in_utf16_units() {
        let text = "select '😀', a from t";
        let caret = u32::try_from(text.encode_utf16().count()).expect("a short text");

        let formatted = format_sql(text.to_owned(), SqlGrammarTag::PostgreSql, caret);

        assert!(formatted.text.contains('\n'), "{}", formatted.text);
        assert_eq!(
            usize::try_from(formatted.caret).expect("a caret"),
            formatted.text.encode_utf16().count()
        );
    }

    #[test]
    fn a_caret_inside_a_literal_keeps_its_place() {
        let text = "select '😀  b', a from t";
        let caret = u32::try_from("select '😀 ".encode_utf16().count()).expect("a short text");

        let formatted = format_sql(text.to_owned(), SqlGrammarTag::PostgreSql, caret);

        let byte = byte_at_unit(&formatted.text, usize::try_from(formatted.caret).expect("a caret"));
        assert!(formatted.text[..byte].ends_with("'😀 "), "{}", formatted.text);
        assert!(formatted.text[byte..].starts_with(" b'"), "{}", formatted.text);
    }

    #[test]
    fn a_selection_counts_utf16_units_and_keeps_its_context() {
        let selected = "select a,b from t";
        for (prefix, suffix) in [("select '😀'; ", ";"), ("select '😀 ", "'")] {
            let text = format!("{prefix}{selected}{suffix}");
            let start = u32::try_from(prefix.encode_utf16().count()).expect("a short prefix");
            let end = start + u32::try_from(selected.encode_utf16().count()).expect("a short selection");

            let formatted = format_sql_selection(text, SqlGrammarTag::PostgreSql, start, end);

            if prefix.ends_with("; ") {
                assert!(formatted.contains('\n'), "{formatted}");
            } else {
                assert_eq!(formatted, selected);
            }
        }
    }

    #[test]
    fn a_language_that_is_not_sql_is_left_as_it_is() {
        let formatted = format_sql("GET  key".to_owned(), SqlGrammarTag::Redis, 3);

        assert_eq!((formatted.text.as_str(), formatted.caret), ("GET  key", 3));
        assert_eq!(
            format_sql_selection("GET  key".to_owned(), SqlGrammarTag::Redis, 0, 8),
            "GET  key"
        );
    }
}
