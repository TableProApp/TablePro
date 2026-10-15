use tablepro_core::sql_dialect::quote_ident;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

fn plan(text: &str, grammar: Option<SqlGrammar>) -> ScriptPlan {
    let grammar = grammar.unwrap_or(SqlGrammar::Sqlite);
    ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
}

pub(crate) fn split_table_reference(text: &str, grammar: Option<SqlGrammar>) -> Option<(Option<String>, String)> {
    let plan = plan(text, grammar);
    if !plan.diagnostics().is_empty() {
        return None;
    }
    let tokens: Vec<_> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    let components = match tokens.as_slice() {
        [name] => vec![name],
        [schema, dot, name] if &text[dot.range.clone()] == "." => vec![schema, name],
        _ => return None,
    };
    let mut names = Vec::new();
    for token in components {
        let raw = &text[token.range.clone()];
        let name = match token.kind {
            ScriptTokenKind::Word if grammar == Some(SqlGrammar::PostgreSql) => raw.to_ascii_lowercase(),
            ScriptTokenKind::Word => raw.to_string(),
            ScriptTokenKind::QuotedIdentifier => quoted_name(raw, grammar)?,
            _ => return None,
        };
        if name.is_empty() || name.contains('\0') {
            return None;
        }
        names.push(name);
    }
    let table = names.pop()?;
    Some((names.pop(), table))
}

fn quoted_name(raw: &str, grammar: Option<SqlGrammar>) -> Option<String> {
    let closing = raw.chars().last()?;
    let body = raw.get(1..raw.len() - closing.len_utf8())?;
    let mut chars = body.chars().peekable();
    let mut name = String::new();
    while let Some(character) = chars.next() {
        if character == '\\' && grammar == Some(SqlGrammar::ClickHouse) {
            name.push(chars.next()?);
            continue;
        }
        if character == closing && chars.peek() == Some(&closing) {
            chars.next();
        }
        name.push(character);
    }
    Some(name)
}

pub(crate) fn table_key(text: &str, grammar: Option<SqlGrammar>) -> Option<String> {
    let grammar = Some(grammar.unwrap_or(SqlGrammar::PostgreSql));
    let (mut schema, mut table) = split_table_reference(text, grammar)?;
    if grammar != Some(SqlGrammar::PostgreSql) {
        schema = schema.map(|name| name.to_ascii_lowercase());
        table.make_ascii_lowercase();
    }
    Some(match schema {
        Some(schema) => format!("{schema}\0{table}"),
        None => table,
    })
}

pub(super) fn bare_reference(text: &str, grammar: Option<SqlGrammar>) -> Option<String> {
    split_table_reference(text, grammar)?;
    let plan = plan(text, grammar);
    let token = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .last()?;
    Some(text[token.range].to_string())
}

pub(super) fn words(text: &str, grammar: Option<SqlGrammar>) -> Vec<&str> {
    let plan = plan(text, grammar);
    let tokens: Vec<_> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    let mut words = Vec::new();
    let mut index = 0;
    while let Some(token) = tokens.get(index) {
        if !matches!(token.kind, ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier) {
            index += 1;
            continue;
        }
        let start = token.range.start;
        let mut end = token.range.end;
        index += 1;
        while let Some(dot) = tokens.get(index).filter(|dot| &text[dot.range.clone()] == ".") {
            end = dot.range.end;
            index += 1;
            let Some(name) = tokens.get(index).filter(|name| {
                name.kind == ScriptTokenKind::QuotedIdentifier
                    || (name.kind == ScriptTokenKind::Word
                        && !super::completion::KEYWORDS
                            .contains(&text[name.range.clone()].to_ascii_lowercase().as_str()))
            }) else {
                break;
            };
            end = name.range.end;
            index += 1;
        }
        words.push(&text[start..end]);
    }
    words
}

pub(crate) fn catalog_reference(driver: &str, schema: Option<&str>, table: &str) -> String {
    let table = quote_ident(driver, table);
    match schema {
        Some(schema) => format!("{}.{table}", quote_ident(driver, schema)),
        None => table,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_names_round_trip_through_each_engine_quoting() {
        for (driver, grammar) in [
            ("postgres", SqlGrammar::PostgreSql),
            ("mysql", SqlGrammar::MySql),
            ("mssql", SqlGrammar::MsSql),
            ("sqlite", SqlGrammar::Sqlite),
            ("clickhouse", SqlGrammar::ClickHouse),
        ] {
            for name in ["Users", "a.b", "a\"b", "with space", "東京", "a`b", "a]b", "a\\b"] {
                let sql = catalog_reference(driver, Some("odd.schema"), name);
                assert_eq!(
                    split_table_reference(&sql, Some(grammar)),
                    Some((Some("odd.schema".into()), name.into())),
                    "{driver}: {sql}"
                );
            }
        }
    }
}
