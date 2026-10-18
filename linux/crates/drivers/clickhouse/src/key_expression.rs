//! The parts of a table key, read from the expression the server keeps
//! for it (`system.tables.sorting_key`, a skipping index's `expr`).
//!
//! sqlparser parses the list, so a comma inside `toYYYYMM(d)` or a
//! quoted name never splits a key, and its tokens find the columns a key
//! names in the order it names them.

use sqlparser::ast::{Expr, OrderByExpr, OrderBySort};
use sqlparser::dialect::ClickHouseDialect;
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer};
use tablepro_core::meta::IndexKey;

/// One key per entry of the list. A list sqlparser cannot read is kept
/// whole, as the server wrote it.
pub(crate) fn index_keys(text: &str) -> Vec<IndexKey> {
    let text = text.trim();
    if text.is_empty() {
        return Vec::new();
    }
    match parse_list(text) {
        Some(keys) => keys.into_iter().map(key).collect(),
        None => vec![IndexKey::Expression {
            sql: text.to_owned(),
            descending: false,
        }],
    }
}

fn parse_list(text: &str) -> Option<Vec<OrderByExpr>> {
    let dialect = ClickHouseDialect {};
    let mut parser = Parser::new(&dialect).try_with_sql(text).ok()?;
    let keys = parser.parse_comma_separated(Parser::parse_order_by_expr).ok()?;
    (parser.peek_token().token == Token::EOF).then_some(keys)
}

fn key(entry: OrderByExpr) -> IndexKey {
    let descending = matches!(entry.options.sort, Some(OrderBySort::Desc));
    match entry.expr {
        Expr::Identifier(ident) => IndexKey::Column {
            name: ident.value,
            descending,
        },
        other => IndexKey::Expression {
            sql: other.to_string(),
            descending,
        },
    }
}

/// `columns`, which the catalogue flagged as part of the key, in the
/// order the key expression first names them. A column the expression
/// does not visibly name keeps its catalogue position after the rest.
pub(crate) fn columns_in_key_order(text: &str, columns: &[String]) -> Vec<String> {
    let dialect = ClickHouseDialect {};
    let tokens = Tokenizer::new(&dialect, text).tokenize().unwrap_or_default();
    let mut ordered: Vec<String> = Vec::with_capacity(columns.len());
    for (position, token) in tokens.iter().enumerate() {
        let Token::Word(word) = token else {
            continue;
        };
        // A word followed by a parenthesis is a function, not a column.
        let called = matches!(next_significant(&tokens, position + 1), Some(Token::LParen));
        if called || ordered.contains(&word.value) || !columns.contains(&word.value) {
            continue;
        }
        ordered.push(word.value.clone());
    }
    for column in columns {
        if !ordered.contains(column) {
            ordered.push(column.clone());
        }
    }
    ordered
}

fn next_significant(tokens: &[Token], from: usize) -> Option<&Token> {
    tokens
        .iter()
        .skip(from)
        .find(|token| !matches!(token, Token::Whitespace(_)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str) -> IndexKey {
        IndexKey::Column {
            name: name.to_owned(),
            descending: false,
        }
    }

    #[test]
    fn a_key_list_splits_at_top_level_commas_only() {
        assert_eq!(index_keys("id"), vec![column("id")]);
        assert_eq!(index_keys("`a`, `b`"), vec![column("a"), column("b")]);
        assert_eq!(
            index_keys("toYYYYMM(d), id"),
            vec![
                IndexKey::Expression {
                    sql: "toYYYYMM(d)".to_owned(),
                    descending: false
                },
                column("id")
            ]
        );
        assert!(index_keys("").is_empty());
    }

    #[test]
    fn a_descending_key_says_so() {
        assert_eq!(
            index_keys("id DESC"),
            vec![IndexKey::Column {
                name: "id".to_owned(),
                descending: true
            }]
        );
    }

    #[test]
    fn key_columns_follow_the_expression_not_the_table() {
        let flagged = ["id".to_owned(), "d".to_owned()];

        assert_eq!(columns_in_key_order("toYYYYMM(d), id", &flagged), ["d", "id"]);
        assert_eq!(columns_in_key_order("`id`", &flagged[..1]), ["id"]);
        assert_eq!(
            columns_in_key_order("cityHash64(x)", &flagged),
            ["id", "d"],
            "flagged columns the text does not name keep their order"
        );
    }
}
