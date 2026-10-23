//! What a table's CREATE TABLE text says about its columns.
//!
//! DuckDB's catalogue functions list a generated column's expression as
//! its default and a column's collation nowhere, so the only record of
//! either is the CREATE TABLE text DuckDB keeps, where a column reads
//! `name type [COLLATE collation] [GENERATED ALWAYS AS (expression)]`.

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// One element of the column list: a column, or a table constraint,
/// which no column name matches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeclaredColumn {
    pub(crate) name: String,
    pub(crate) generated: bool,
    /// The collation it compares under instead of byte for byte, as the
    /// text spells it, `nocase.noaccent` for two.
    pub(crate) collation: Option<String>,
}

/// The column list of `create_sql`, with names as the table's own text
/// spells them.
pub(crate) fn declared_columns(create_sql: &str) -> Vec<DeclaredColumn> {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(create_sql, grammar, LexicalSettings::default_for(grammar));
    let mut declared = Vec::new();
    let mut depth = 0usize;
    // The element's tokens and the depth each sits at, 1 being the
    // column list itself.
    let mut element: Vec<(ScriptTokenKind, &str, usize)> = Vec::new();
    for token in plan.tokens(0..create_sql.len()).filter(|token| !token.kind.is_trivia()) {
        let text = create_sql.get(token.range.clone()).unwrap_or_default();
        match token.kind {
            ScriptTokenKind::OpenParen => {
                depth += 1;
                if depth == 1 {
                    continue;
                }
            }
            ScriptTokenKind::CloseParen => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    declared.extend(take(&mut element));
                    continue;
                }
            }
            ScriptTokenKind::Punct if text == "," && depth == 1 => {
                declared.extend(take(&mut element));
                continue;
            }
            _ => {}
        }
        if depth >= 1 {
            element.push((token.kind, text, depth));
        }
    }
    declared
}

/// Close one element of the column list.
fn take(element: &mut Vec<(ScriptTokenKind, &str, usize)>) -> Option<DeclaredColumn> {
    let own: Vec<(ScriptTokenKind, &str)> = element
        .iter()
        .filter(|(_, _, depth)| *depth == 1)
        .map(|(kind, text, _)| (*kind, *text))
        .collect();
    let words: Vec<String> = own
        .iter()
        .filter(|(kind, _)| *kind == ScriptTokenKind::Word)
        .map(|(_, text)| text.to_ascii_uppercase())
        .collect();
    let name = match element.first() {
        Some((ScriptTokenKind::QuotedIdentifier, name, _)) => Some(unquote(name)),
        Some((ScriptTokenKind::Word, name, _)) => Some((*name).to_owned()),
        _ => None,
    };
    element.clear();
    Some(DeclaredColumn {
        name: name?,
        generated: words.windows(3).any(|window| window == ["GENERATED", "ALWAYS", "AS"]),
        collation: collation(&own),
    })
}

/// The name after COLLATE: one or more names joined by dots.
fn collation(tokens: &[(ScriptTokenKind, &str)]) -> Option<String> {
    let is_name = |kind: ScriptTokenKind| matches!(kind, ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier);
    let at = tokens
        .iter()
        .position(|(kind, text)| *kind == ScriptTokenKind::Word && text.eq_ignore_ascii_case("COLLATE"))?;
    let mut rest = tokens.get(at + 1..)?.iter();
    let mut name = rest.next().filter(|(kind, _)| is_name(*kind))?.1.to_owned();
    while let (Some((ScriptTokenKind::Punct, ".")), Some((kind, part))) = (rest.next().copied(), rest.next().copied()) {
        if !is_name(kind) {
            break;
        }
        name.push('.');
        name.push_str(part);
    }
    Some(name)
}

fn unquote(quoted: &str) -> String {
    quoted
        .strip_prefix('"')
        .and_then(|inner| inner.strip_suffix('"'))
        .unwrap_or(quoted)
        .replace("\"\"", "\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn named(sql: &str, pick: fn(&DeclaredColumn) -> bool) -> Vec<String> {
        declared_columns(sql)
            .into_iter()
            .filter(pick)
            .map(|column| column.name)
            .collect()
    }

    #[test]
    fn generated_columns_are_found_in_the_stored_create_statement() {
        let sql = "CREATE TABLE child(id BIGINT DEFAULT(nextval('s1')), pid INTEGER, \
                   total INTEGER GENERATED ALWAYS AS((pid * 2)), \"odd, name\" VARCHAR GENERATED ALWAYS AS((CAST(pid AS VARCHAR))), \
                   note VARCHAR DEFAULT('generated always as'), FOREIGN KEY (pid) REFERENCES parent(id), PRIMARY KEY(id));";

        assert_eq!(named(sql, |column| column.generated), ["total", "odd, name"]);
    }

    #[test]
    fn a_collation_counts_only_on_the_column_itself() {
        let sql = "CREATE TABLE c(code VARCHAR COLLATE NOCASE, \"Region\" VARCHAR COLLATE nocase.noaccent NOT NULL, \
                   plain VARCHAR DEFAULT(('x' COLLATE NOCASE)), note VARCHAR, \
                   CHECK((note COLLATE NOCASE = 'x')), FOREIGN KEY (code) REFERENCES p(code));";

        let collations: Vec<(String, String)> = declared_columns(sql)
            .into_iter()
            .filter_map(|column| Some((column.name, column.collation?)))
            .collect();

        assert_eq!(
            collations,
            [
                ("code".to_owned(), "NOCASE".to_owned()),
                ("Region".to_owned(), "nocase.noaccent".to_owned())
            ]
        );
    }

    #[test]
    fn a_table_with_none_has_none() {
        let sql = "CREATE TABLE t(a INTEGER, b VARCHAR);";

        assert!(named(sql, |column| column.generated || column.collation.is_some()).is_empty());
        assert_eq!(named(sql, |_| true), ["a", "b"]);
    }
}
