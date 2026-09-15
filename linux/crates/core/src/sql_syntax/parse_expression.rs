use sqlparser::ast::{Expr, UnaryOperator, Value as AstValue};
use sqlparser::parser::Parser;
use sqlparser::tokenizer::Token;

use super::SqlGrammar;
use super::errors::ExpressionSyntaxError;
use super::literal_token::LiteralToken;
use super::parse_type::{RECURSION_LIMIT, reject_comment_tokens};
use crate::value::SqlDecimal;

/// An expression the engine's own parser accepted, plus the literal it
/// reduces to when it is one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedExpression {
    pub text: String,
    /// `None` for anything only the server can evaluate, such as `now()`.
    pub literal: Option<LiteralToken>,
}

/// A DEFAULT clause or a filter value. Long enough for a generated
/// expression, short enough that a pasted statement is refused.
pub const MAX_EXPRESSION_LEN: usize = 4096;

pub fn parse_expression(
    grammar: SqlGrammar,
    text: &str,
    max_len: usize,
) -> Result<ValidatedExpression, ExpressionSyntaxError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(ExpressionSyntaxError::Empty);
    }
    if text.chars().count() > max_len {
        return Err(ExpressionSyntaxError::TooLong { max: max_len });
    }
    if reject_comment_tokens(grammar, text).is_err() && (text.contains("--") || text.contains("/*")) {
        return Err(ExpressionSyntaxError::Comment);
    }

    let mut parser = Parser::new(grammar.parser_dialect())
        .with_recursion_limit(RECURSION_LIMIT)
        .try_with_sql(text)
        .map_err(|error| ExpressionSyntaxError::Invalid(error.to_string()))?;
    let parsed = parser
        .parse_expr()
        .map_err(|error| ExpressionSyntaxError::Invalid(error.to_string()))?;
    if parser.peek_token_ref().token != Token::EOF {
        return Err(ExpressionSyntaxError::Invalid(
            "unexpected text after the expression".to_owned(),
        ));
    }
    Ok(ValidatedExpression {
        text: text.to_owned(),
        literal: literal_of(&parsed),
    })
}

/// Peel the wrappers a user or a catalogue adds around a literal:
/// parentheses and a cast both leave the value itself unchanged.
fn literal_of(expr: &Expr) -> Option<LiteralToken> {
    match expr {
        Expr::Nested(inner) => literal_of(inner),
        Expr::Cast { expr, .. } => literal_of(expr),
        Expr::UnaryOp {
            op: UnaryOperator::Minus,
            expr,
        } => match literal_of(expr)? {
            LiteralToken::Number(number) => negate(&number),
            _ => None,
        },
        Expr::UnaryOp {
            op: UnaryOperator::Plus,
            expr,
        } => literal_of(expr),
        Expr::Value(value) => value_literal(&value.value),
        _ => None,
    }
}

fn value_literal(value: &AstValue) -> Option<LiteralToken> {
    match value {
        AstValue::SingleQuotedString(text)
        | AstValue::DoubleQuotedString(text)
        | AstValue::NationalStringLiteral(text)
        | AstValue::EscapedStringLiteral(text)
        | AstValue::UnicodeStringLiteral(text) => Some(LiteralToken::Text(text.clone())),
        AstValue::Number(text, _) => text.parse::<SqlDecimal>().ok().map(LiteralToken::Number),
        AstValue::Boolean(flag) => Some(LiteralToken::Boolean(*flag)),
        AstValue::Null => Some(LiteralToken::Null),
        _ => None,
    }
}

fn negate(number: &SqlDecimal) -> Option<LiteralToken> {
    let text = number.to_string();
    let negated = match text.strip_prefix('-') {
        Some(rest) => rest.to_owned(),
        None => format!("-{text}"),
    };
    negated.parse::<SqlDecimal>().ok().map(LiteralToken::Number)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Result<ValidatedExpression, ExpressionSyntaxError> {
        parse_expression(SqlGrammar::PostgreSql, text, MAX_EXPRESSION_LEN)
    }

    fn number(text: &str) -> LiteralToken {
        LiteralToken::Number(text.parse().expect("a valid decimal"))
    }

    #[test]
    fn literal_token_table() {
        let cases: [(&str, Option<LiteralToken>); 7] = [
            ("'hi'::text", Some(LiteralToken::Text("hi".to_owned()))),
            ("-5", Some(number("-5"))),
            ("((0))", Some(number("0"))),
            ("N'x'", Some(LiteralToken::Text("x".to_owned()))),
            ("true", Some(LiteralToken::Boolean(true))),
            ("null", Some(LiteralToken::Null)),
            ("now()", None),
        ];

        for (text, expected) in cases {
            let parsed = parse(text).unwrap_or_else(|error| panic!("{text}: {error}"));
            assert_eq!(parsed.literal, expected, "{text}");
        }
    }

    #[test]
    fn a_double_negative_returns_to_positive() {
        assert_eq!(parse("-(-5)").expect("nested minus").literal, Some(number("5")));
    }

    #[test]
    fn parse_expression_rejects_trailing_tokens() {
        let error = parse("1; DROP TABLE x").expect_err("trailing statement");

        assert!(matches!(error, ExpressionSyntaxError::Invalid(_)), "{error:?}");
    }

    #[test]
    fn parse_expression_rejects_comments_and_empty() {
        assert_eq!(parse("1 -- x"), Err(ExpressionSyntaxError::Comment));
        assert_eq!(parse("1 /* x */"), Err(ExpressionSyntaxError::Comment));
        assert_eq!(parse("  "), Err(ExpressionSyntaxError::Empty));
        assert_eq!(
            parse_expression(SqlGrammar::PostgreSql, "now()", 2),
            Err(ExpressionSyntaxError::TooLong { max: 2 })
        );
    }
}
