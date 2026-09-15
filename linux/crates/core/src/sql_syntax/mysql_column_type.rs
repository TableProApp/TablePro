use sqlparser::parser::Parser;
use sqlparser::tokenizer::Token;

use super::SqlGrammar;
use super::errors::TypeSyntaxError;
use super::parse_type::{MAX_TYPE_LEN, RECURSION_LIMIT, TypeShape, reject_comment_tokens, shape_of};

/// What MySQL's `information_schema.columns.column_type` says about a
/// column, which is more than `parse_type` can report because sqlparser
/// has no ZEROFILL keyword.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MySqlColumnTypeFacts {
    pub shape: TypeShape,
    /// `zerofill` pads the displayed value with leading zeros and implies
    /// UNSIGNED, so the grid right-aligns and the DDL keeps the keyword.
    pub zerofill: bool,
}

/// Parse a MySQL `column_type` string, consuming a trailing `zerofill`
/// that sqlparser 0.63.0 does not know.
pub fn mysql_column_type(column_type: &str) -> Result<MySqlColumnTypeFacts, TypeSyntaxError> {
    let text = column_type.trim();
    if text.is_empty() {
        return Err(TypeSyntaxError::Empty);
    }
    if text.chars().count() > MAX_TYPE_LEN {
        return Err(TypeSyntaxError::TooLong { max: MAX_TYPE_LEN });
    }
    if reject_comment_tokens(SqlGrammar::MySql, text).is_err() && (text.contains("--") || text.contains("/*")) {
        return Err(TypeSyntaxError::Comment);
    }

    let mut parser = Parser::new(SqlGrammar::MySql.parser_dialect())
        .with_recursion_limit(RECURSION_LIMIT)
        .try_with_sql(text)
        .map_err(|error| TypeSyntaxError::Invalid(error.to_string()))?;
    let parsed = parser
        .parse_data_type()
        .map_err(|error| TypeSyntaxError::Invalid(error.to_string()))?;

    // Exactly one unquoted `zerofill` may follow, and nothing after it.
    let mut zerofill = false;
    if let Token::Word(word) = &parser.peek_token_ref().token
        && word.quote_style.is_none()
        && word.value.eq_ignore_ascii_case("zerofill")
    {
        parser.next_token();
        zerofill = true;
    }
    if parser.peek_token_ref().token != Token::EOF {
        return Err(TypeSyntaxError::Invalid("unexpected text after the type".to_owned()));
    }

    Ok(MySqlColumnTypeFacts {
        shape: shape_of(&parsed),
        zerofill,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mysql_column_type_zerofill_tail() {
        let facts = mysql_column_type("int(10) unsigned zerofill").expect("int zerofill");
        assert_eq!(facts.shape, TypeShape::Named { unsigned: true });
        assert!(facts.zerofill);

        let facts = mysql_column_type("decimal(10,2) unsigned zerofill").expect("decimal zerofill");
        assert_eq!(facts.shape, TypeShape::Named { unsigned: true });
        assert!(facts.zerofill);

        for text in ["int zerofill zerofill", "int zerofill x"] {
            let error = mysql_column_type(text).expect_err(text);
            assert!(matches!(error, TypeSyntaxError::Invalid(_)), "{text}: {error:?}");
        }
    }

    #[test]
    fn a_type_without_the_tail_is_not_zerofill() {
        let facts = mysql_column_type("varchar(255)").expect("varchar");

        assert_eq!(facts.shape, TypeShape::Named { unsigned: false });
        assert!(!facts.zerofill);
    }

    #[test]
    fn a_quoted_zerofill_is_not_the_keyword() {
        let error = mysql_column_type("int `zerofill`").expect_err("quoted tail");

        assert!(matches!(error, TypeSyntaxError::Invalid(_)), "{error:?}");
    }

    #[test]
    fn tinyint_display_width_survives_the_tail() {
        let facts = mysql_column_type("tinyint(1) unsigned zerofill").expect("tinyint");

        assert_eq!(
            facts.shape,
            TypeShape::TinyIntDisplayWidth {
                width: Some(1),
                unsigned: true
            }
        );
        assert!(facts.zerofill);
    }
}
