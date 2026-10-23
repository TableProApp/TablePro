//! Which columns of a table are generated.
//!
//! DuckDB's catalogue functions list a generated column's expression as
//! its default and say nothing else about it, so the only record is the
//! CREATE TABLE text DuckDB keeps, where each one reads
//! `name type GENERATED ALWAYS AS (expression)`.

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// The names of the generated columns in `create_sql`, as the table's
/// own text spells them.
pub(crate) fn generated_columns(create_sql: &str) -> Vec<String> {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(create_sql, grammar, LexicalSettings::default_for(grammar));
    let tokens: Vec<_> = plan
        .tokens(0..create_sql.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    let mut generated = Vec::new();
    let mut depth = 0usize;
    let mut element: Vec<(ScriptTokenKind, &str)> = Vec::new();
    for token in &tokens {
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
                    take(&mut element, &mut generated);
                    continue;
                }
            }
            ScriptTokenKind::Punct if text == "," && depth == 1 => {
                take(&mut element, &mut generated);
                continue;
            }
            _ => {}
        }
        if depth >= 1 {
            element.push((token.kind, text));
        }
    }
    generated
}

/// Close one element of the column list, keeping its name when it is a
/// generated column.
fn take(element: &mut Vec<(ScriptTokenKind, &str)>, generated: &mut Vec<String>) {
    let words: Vec<&str> = element
        .iter()
        .filter(|(kind, _)| *kind == ScriptTokenKind::Word)
        .map(|(_, text)| *text)
        .collect();
    let is_generated = words.windows(3).any(|window| {
        window
            .iter()
            .map(|word| word.to_ascii_uppercase())
            .eq(["GENERATED", "ALWAYS", "AS"])
    });
    if is_generated && let Some((kind, name)) = element.first() {
        match kind {
            ScriptTokenKind::QuotedIdentifier => generated.push(unquote(name)),
            ScriptTokenKind::Word => generated.push((*name).to_owned()),
            _ => {}
        }
    }
    element.clear();
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

    #[test]
    fn generated_columns_are_found_in_the_stored_create_statement() {
        let sql = "CREATE TABLE child(id BIGINT DEFAULT(nextval('s1')), pid INTEGER, \
                   total INTEGER GENERATED ALWAYS AS((pid * 2)), \"odd, name\" VARCHAR GENERATED ALWAYS AS((CAST(pid AS VARCHAR))), \
                   note VARCHAR DEFAULT('generated always as'), FOREIGN KEY (pid) REFERENCES parent(id), PRIMARY KEY(id));";

        assert_eq!(generated_columns(sql), ["total", "odd, name"]);
    }

    #[test]
    fn a_table_with_none_has_none() {
        assert!(generated_columns("CREATE TABLE t(a INTEGER, b VARCHAR);").is_empty());
    }
}
