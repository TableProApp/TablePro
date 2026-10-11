use sqlparser::ast::{Expr, Select, TableFactor};
use sqlparser::dialect::GenericDialect;
use sqlparser::keywords::Keyword;
use sqlparser::tokenizer::{Token, Tokenizer};

pub(super) fn source_records(select: &Select) -> Option<Vec<String>> {
    select
        .from
        .iter()
        .flat_map(|table| std::iter::once(&table.relation).chain(table.joins.iter().map(|join| &join.relation)))
        .map(source_record)
        .collect()
}

fn source_record(relation: &TableFactor) -> Option<String> {
    let TableFactor::Table {
        name,
        alias,
        args: None,
        json_path: None,
        ..
    } = relation
    else {
        return None;
    };
    if let Some(alias) = alias {
        return alias.columns.is_empty().then(|| alias.name.value.to_lowercase());
    }
    name.0.last()?.as_ident().map(|name| name.value.to_lowercase())
}

pub(super) fn references_record(expr: &Expr, records: &[String]) -> bool {
    let rendered = expr.to_string();
    let Ok(tokens) = Tokenizer::new(&GenericDialect, &rendered).tokenize() else {
        return true;
    };
    let tokens: Vec<_> = tokens
        .into_iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .collect();
    tokens.iter().enumerate().any(|(index, token)| {
        if matches!(token, Token::Word(word) if matches!(word.keyword, Keyword::SELECT | Keyword::WITH)) {
            return true;
        }
        matches!(token, Token::Word(word) if records.contains(&word.value.to_lowercase()))
            && (!matches!(tokens.get(index + 1), Some(Token::Period))
                || matches!(tokens.get(index + 2), Some(Token::Mul)))
    })
}
