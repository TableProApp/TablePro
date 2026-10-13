use std::ops::Range;

use tablepro_core::TableRef;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

/// What the text before the cursor asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompletionScope {
    /// A table or view to name, from `schema` or the default one.
    Objects { schema: Option<String> },
    /// A column of one of these tables.
    Columns { tables: Vec<TableRef> },
    /// Anything: keywords, objects, and the columns of the tables the
    /// statement already names.
    General { tables_in_statement: Vec<TableRef> },
}

/// The words after which a table name comes.
const RELATION_WORDS: [&str; 5] = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"];

/// Words that are never an alias, beyond the completed keywords.
const CLAUSE_WORDS: [&str; 12] = [
    "FETCH",
    "FINAL",
    "FOR",
    "LATERAL",
    "LIMIT",
    "NATURAL",
    "OFFSET",
    "ONLY",
    "PREWHERE",
    "RETURNING",
    "TABLESAMPLE",
    "WINDOW",
];

/// What to complete at byte `cursor` of `text`.
///
/// `None` inside a string, a comment, a quoted name or a dollar-quoted
/// body: what is typed there is not SQL the editor can read.
pub fn analyze(text: &str, cursor: usize, grammar: SqlGrammar, settings: LexicalSettings) -> Option<CompletionScope> {
    let cursor = floor_char_boundary(text, cursor);
    let plan = ScriptPlan::build(text, grammar, settings);
    if plan
        .tokens(cursor.saturating_sub(1)..cursor + 1)
        .any(|token| encloses(&token, cursor))
    {
        return None;
    }
    let Some(statement) = statement_around(&plan, cursor) else {
        return Some(CompletionScope::General {
            tables_in_statement: Vec::new(),
        });
    };
    let lexemes: Vec<Lexeme<'_>> = plan
        .tokens(statement)
        .filter(|token| !token.kind.is_trivia())
        .filter_map(|token| Lexeme::new(text, token))
        .collect();
    let tables = TableMap::collect(&lexemes, grammar);
    let mut before: Vec<&Lexeme<'_>> = lexemes.iter().take_while(|lexeme| lexeme.end <= cursor).collect();
    if before
        .last()
        .is_some_and(|last| last.kind == ScriptTokenKind::Word && last.end == cursor)
    {
        before.pop();
    }
    Some(scope_after(&before, &tables, grammar))
}

fn scope_after(before: &[&Lexeme<'_>], tables: &TableMap, grammar: SqlGrammar) -> CompletionScope {
    let general = || CompletionScope::General {
        tables_in_statement: tables.in_order(),
    };
    let Some((last, rest)) = before.split_last() else {
        return general();
    };
    if last.is_punct(".") {
        return after_dot(rest, tables).unwrap_or_else(general);
    }
    if RELATION_WORDS.iter().any(|word| last.is_word(word)) || (last.is_punct(",") && in_from_list(rest, grammar)) {
        return CompletionScope::Objects { schema: None };
    }
    general()
}

/// `name.` names a table's columns when the statement knows the name,
/// and a schema's objects otherwise; `schema.table.` is always columns.
fn after_dot(rest: &[&Lexeme<'_>], tables: &TableMap) -> Option<CompletionScope> {
    let (name, rest) = rest.split_last()?;
    let name = name.identifier()?;
    if let [.., schema, dot] = rest
        && dot.is_punct(".")
        && let Some(schema) = schema.identifier()
    {
        return Some(CompletionScope::Columns {
            tables: vec![TableRef::new(Some(schema), name)],
        });
    }
    Some(match tables.lookup(&name) {
        Some(table) => CompletionScope::Columns {
            tables: vec![table.clone()],
        },
        None => CompletionScope::Objects { schema: Some(name) },
    })
}

/// Whether a comma continues the table list of a FROM clause.
fn in_from_list(rest: &[&Lexeme<'_>], grammar: SqlGrammar) -> bool {
    for lexeme in rest.iter().rev() {
        if lexeme.is_word("FROM") {
            return true;
        }
        let part_of_list = lexeme.is_punct(",")
            || lexeme.is_punct(".")
            || lexeme.is_word("AS")
            || (lexeme.identifier().is_some() && !lexeme.is_keyword(grammar));
        if !part_of_list {
            return false;
        }
    }
    false
}

/// The tables a statement names, under their aliases and their own
/// names.
#[derive(Debug, Default)]
struct TableMap {
    entries: Vec<(String, TableRef)>,
}

impl TableMap {
    /// Every relation word starts a reference, including those inside a
    /// subquery, so a cursor in the subquery sees its tables too.
    fn collect(lexemes: &[Lexeme<'_>], grammar: SqlGrammar) -> Self {
        let mut map = Self::default();
        for (index, lexeme) in lexemes.iter().enumerate() {
            let Some(keyword) = RELATION_WORDS.iter().find(|word| lexeme.is_word(word)) else {
                continue;
            };
            let mut at = index + 1;
            loop {
                if lexemes.get(at).is_some_and(|next| next.is_word("ONLY")) {
                    at += 1;
                }
                let table = if lexemes.get(at).is_some_and(Lexeme::opens_group) {
                    at = after_group(lexemes, at);
                    None
                } else {
                    let Some((table, next)) = table_ref_at(lexemes, at, grammar) else {
                        break;
                    };
                    at = next;
                    // A set-returning call in FROM is not a table, and
                    // its arguments are no alias.
                    let called = lexemes.get(at).is_some_and(Lexeme::opens_group);
                    if called && matches!(*keyword, "FROM" | "JOIN") {
                        at = after_group(lexemes, at);
                        None
                    } else {
                        Some(table)
                    }
                };
                let (alias, next) = alias_at(lexemes, at, grammar);
                at = next;
                if let Some(table) = table {
                    map.insert(table, alias);
                }
                if *keyword == "FROM" && lexemes.get(at).is_some_and(|next| next.is_punct(",")) {
                    at += 1;
                    continue;
                }
                break;
            }
        }
        map
    }

    fn insert(&mut self, table: TableRef, alias: Option<String>) {
        if let Some(alias) = alias {
            self.entries.push((alias, table.clone()));
        }
        self.entries.push((table.name.clone(), table));
    }

    /// The table `name` stands for, matched as written first and then
    /// ignoring case, the way an unquoted name is read.
    fn lookup(&self, name: &str) -> Option<&TableRef> {
        let folded = name.to_lowercase();
        self.entries
            .iter()
            .find(|(key, _)| key == name)
            .or_else(|| self.entries.iter().find(|(key, _)| key.to_lowercase() == folded))
            .map(|(_, table)| table)
    }

    fn in_order(&self) -> Vec<TableRef> {
        let mut tables: Vec<TableRef> = Vec::new();
        for (_, table) in &self.entries {
            if !tables.contains(table) {
                tables.push(table.clone());
            }
        }
        tables
    }
}

/// `name`, `schema.name` or `catalog.schema.name` at `index`, and the
/// index after it.
fn table_ref_at(lexemes: &[Lexeme<'_>], index: usize, grammar: SqlGrammar) -> Option<(TableRef, usize)> {
    let mut parts = Vec::new();
    let mut at = index;
    loop {
        let lexeme = lexemes.get(at)?;
        if lexeme.is_keyword(grammar) {
            break;
        }
        parts.push(lexeme.identifier()?);
        at += 1;
        match lexemes.get(at) {
            Some(dot) if dot.is_punct(".") => at += 1,
            _ => break,
        }
    }
    let name = parts.pop()?;
    Some((TableRef::new(parts.pop(), name), at))
}

/// The index after the parenthesised group that opens at `index`.
fn after_group(lexemes: &[Lexeme<'_>], index: usize) -> usize {
    let mut depth = 0_usize;
    for (at, lexeme) in lexemes.iter().enumerate().skip(index) {
        match lexeme.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return at + 1;
                }
            }
            _ => {}
        }
    }
    lexemes.len()
}

fn alias_at(lexemes: &[Lexeme<'_>], index: usize, grammar: SqlGrammar) -> (Option<String>, usize) {
    let Some(lexeme) = lexemes.get(index) else {
        return (None, index);
    };
    if lexeme.is_word("AS") {
        let alias = lexemes.get(index + 1).and_then(Lexeme::identifier);
        return (alias, index + 2);
    }
    match lexeme.identifier() {
        Some(alias) if !lexeme.is_keyword(grammar) => (Some(alias), index + 1),
        _ => (None, index),
    }
}

/// The statement the cursor is in or just after, unless a terminator
/// already ended it.
fn statement_around(plan: &ScriptPlan, cursor: usize) -> Option<Range<usize>> {
    let statement = plan.statement_at(cursor)?;
    if cursor <= statement.range.end {
        return Some(statement.range.clone());
    }
    let ended = plan
        .tokens(statement.range.end..cursor)
        .any(|token| matches!(token.kind, ScriptTokenKind::Semicolon | ScriptTokenKind::Directive));
    (!ended).then_some(statement.range.start..cursor)
}

/// Whether the cursor sits inside a token whose text is not SQL. A
/// line comment and an unclosed construct run to their end, so the end
/// counts as inside; a closed quote ends before its last character.
fn encloses(token: &ScriptToken, cursor: usize) -> bool {
    let inside = token.range.start < cursor && cursor < token.range.end;
    let at_open_end = token.range.start < cursor && cursor == token.range.end;
    match token.kind {
        ScriptTokenKind::LineComment | ScriptTokenKind::Unterminated | ScriptTokenKind::Directive => {
            inside || at_open_end
        }
        ScriptTokenKind::StringLiteral
        | ScriptTokenKind::QuotedIdentifier
        | ScriptTokenKind::DollarQuoted
        | ScriptTokenKind::BlockComment => inside,
        _ => false,
    }
}

fn floor_char_boundary(text: &str, byte: usize) -> usize {
    let mut byte = byte.min(text.len());
    while !text.is_char_boundary(byte) {
        byte -= 1;
    }
    byte
}

#[derive(Debug)]
struct Lexeme<'a> {
    kind: ScriptTokenKind,
    text: &'a str,
    end: usize,
}

impl<'a> Lexeme<'a> {
    fn new(source: &'a str, token: ScriptToken) -> Option<Self> {
        Some(Self {
            kind: token.kind,
            text: source.get(token.range.clone())?,
            end: token.range.end,
        })
    }

    fn is_word(&self, word: &str) -> bool {
        self.kind == ScriptTokenKind::Word && self.text.eq_ignore_ascii_case(word)
    }

    fn is_punct(&self, punct: &str) -> bool {
        self.kind == ScriptTokenKind::Punct && self.text == punct
    }

    fn opens_group(&self) -> bool {
        self.kind == ScriptTokenKind::OpenParen
    }

    fn is_keyword(&self, grammar: SqlGrammar) -> bool {
        self.kind == ScriptTokenKind::Word
            && (grammar.keywords().any(|keyword| self.is_word(keyword))
                || CLAUSE_WORDS.iter().any(|keyword| self.is_word(keyword)))
    }

    /// The name a word or a quoted identifier spells.
    fn identifier(&self) -> Option<String> {
        match self.kind {
            ScriptTokenKind::Word => Some(self.text.to_owned()),
            ScriptTokenKind::QuotedIdentifier => Some(unquote(self.text)),
            _ => None,
        }
    }
}

fn unquote(text: &str) -> String {
    let close = match text.chars().next() {
        Some('"') => '"',
        Some('`') => '`',
        Some('[') => ']',
        _ => return text.to_owned(),
    };
    let inner = text
        .get(1..text.len().saturating_sub(close.len_utf8()))
        .unwrap_or_default();
    inner.replace(&format!("{close}{close}"), &close.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The scope at the `|` in `marked`.
    fn scope_in(grammar: SqlGrammar, marked: &str) -> Option<CompletionScope> {
        let cursor = marked.find('|').expect("a cursor mark");
        let text = marked.replacen('|', "", 1);
        analyze(&text, cursor, grammar, LexicalSettings::default_for(grammar))
    }

    fn scope(marked: &str) -> Option<CompletionScope> {
        scope_in(SqlGrammar::PostgreSql, marked)
    }

    fn table(schema: Option<&str>, name: &str) -> TableRef {
        TableRef::new(schema.map(str::to_owned), name)
    }

    fn columns(tables: Vec<TableRef>) -> Option<CompletionScope> {
        Some(CompletionScope::Columns { tables })
    }

    fn general(tables: Vec<TableRef>) -> Option<CompletionScope> {
        Some(CompletionScope::General {
            tables_in_statement: tables,
        })
    }

    const OBJECTS: Option<CompletionScope> = Some(CompletionScope::Objects { schema: None });

    #[test]
    fn after_from_suggests_objects() {
        assert_eq!(scope("SELECT * FROM |"), OBJECTS);
        assert_eq!(scope("SELECT * FROM us|"), OBJECTS);
        assert_eq!(scope("select * from users u join |"), OBJECTS);
        assert_eq!(scope("SELECT * FROM users u, |"), OBJECTS);
        assert_eq!(scope("INSERT INTO |"), OBJECTS);
        assert_eq!(scope("UPDATE |"), OBJECTS);
    }

    #[test]
    fn alias_dot_suggests_that_tables_columns() {
        assert_eq!(scope("SELECT u.| FROM users u"), columns(vec![table(None, "users")]));
        assert_eq!(
            scope("SELECT u.na| FROM public.users AS u"),
            columns(vec![table(Some("public"), "users")])
        );
        assert_eq!(scope("SELECT users.| FROM users"), columns(vec![table(None, "users")]));
        assert_eq!(
            scope("SELECT public.users.| FROM x"),
            columns(vec![table(Some("public"), "users")])
        );
    }

    #[test]
    fn schema_dot_suggests_schema_objects() {
        assert_eq!(
            scope("SELECT * FROM sales.|"),
            Some(CompletionScope::Objects {
                schema: Some("sales".to_owned())
            })
        );
        assert_eq!(
            scope("SELECT * FROM sales.ord|"),
            Some(CompletionScope::Objects {
                schema: Some("sales".to_owned())
            })
        );
    }

    #[test]
    fn quoted_alias_is_unquoted() {
        assert_eq!(
            scope("SELECT \"Đơn\".| FROM \"Order \"\"Items\"\"\" AS \"Đơn\""),
            columns(vec![table(None, "Order \"Items\"")])
        );
        assert_eq!(
            scope_in(SqlGrammar::MySql, "SELECT o.| FROM `shop`.`order items` o"),
            columns(vec![table(Some("shop"), "order items")])
        );
        assert_eq!(
            scope_in(SqlGrammar::MsSql, "SELECT o.| FROM [dbo].[order]]s] o"),
            columns(vec![table(Some("dbo"), "order]s")])
        );
    }

    #[test]
    fn join_aliases_collected() {
        let text = "SELECT | FROM users u JOIN sales.orders o ON o.user_id = u.id LEFT JOIN items ON true";
        assert_eq!(
            scope(text),
            general(vec![
                table(None, "users"),
                table(Some("sales"), "orders"),
                table(None, "items")
            ])
        );
        assert_eq!(
            scope("SELECT * FROM users u JOIN orders o ON o.| = u.id"),
            columns(vec![table(None, "orders")])
        );
        assert_eq!(
            scope("SELECT * FROM users U WHERE u.|"),
            columns(vec![table(None, "users")]),
            "an unquoted alias is matched without case"
        );
    }

    #[test]
    fn dollar_quoted_text_is_not_analyzed() {
        assert_eq!(scope("SELECT $$ FROM $$ |"), general(Vec::new()));
        assert_eq!(scope("SELECT $$ FROM |$$"), None);
        assert_eq!(scope("SELECT $$ FROM |"), None);
        assert_eq!(
            scope("CREATE FUNCTION f() RETURNS int AS $body$ SELECT * FROM | $body$ LANGUAGE sql"),
            None
        );
    }

    #[test]
    fn strings_and_comments_are_not_completed() {
        assert_eq!(scope("SELECT 'FROM |'"), None);
        assert_eq!(scope("SELECT 1 -- FROM |"), None);
        assert_eq!(scope("SELECT /* FROM | */ 1"), None);
        assert_eq!(scope("SELECT \"us|"), None);
        assert_eq!(scope("SELECT 'a' |"), general(Vec::new()));
    }

    #[test]
    fn a_new_statement_starts_after_the_terminator() {
        assert_eq!(scope("SELECT * FROM users;\n|"), general(Vec::new()));
        assert_eq!(scope("SELECT * FROM users;\nsel|"), general(Vec::new()));
        assert_eq!(
            scope("SELECT * FROM users u WHERE |;\nSELECT 2"),
            general(vec![table(None, "users")])
        );
    }

    #[test]
    fn a_comma_outside_from_is_not_a_table_list() {
        assert_eq!(scope("SELECT a, | FROM users"), general(vec![table(None, "users")]));
        assert_eq!(
            scope("SELECT * FROM users WHERE a IN (1, |)"),
            general(vec![table(None, "users")])
        );
    }

    #[test]
    fn a_call_or_subquery_in_from_is_not_a_table() {
        assert_eq!(
            scope("SELECT | FROM generate_series(1, 3) g, users"),
            general(vec![table(None, "users")])
        );
        assert_eq!(
            scope("SELECT | FROM (SELECT * FROM orders) o, users"),
            general(vec![table(None, "users"), table(None, "orders")])
        );
        assert_eq!(scope("INSERT INTO users (|"), general(vec![table(None, "users")]));
    }

    #[test]
    fn a_multibyte_cursor_does_not_split_a_character() {
        let text = "SELECT * FROM đơn";
        let inside_a_character = text.len() - 2;

        let scope = analyze(
            text,
            inside_a_character,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
        );

        assert_eq!(scope, OBJECTS);
    }
}
