use sqlparser::ast::DataType;
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer, Whitespace};

use super::SqlGrammar;
use super::errors::TypeSyntaxError;

/// A type the engine's own parser accepted, plus what the app needs to
/// know about its shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedType {
    pub text: String,
    pub shape: TypeShape,
}

/// What the parsed type is, reduced to the cases the app treats
/// differently. Everything else is `Named`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeShape {
    /// A plain named type, possibly with a length or precision.
    Named {
        unsigned: bool,
    },
    /// MySQL `tinyint(1)`, which is how it spells boolean. The width is
    /// a display width and not a storage size.
    TinyIntDisplayWidth {
        width: Option<u64>,
        unsigned: bool,
    },
    Enum {
        members: Vec<String>,
    },
    Set {
        members: Vec<String>,
    },
    Array,
    Custom,
}

/// The longest a type may be. A catalogue type is short; anything longer
/// is someone pasting a statement into the field.
pub const MAX_TYPE_LEN: usize = 512;

pub fn parse_type(grammar: SqlGrammar, text: &str, max_len: usize) -> Result<ValidatedType, TypeSyntaxError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(TypeSyntaxError::Empty);
    }
    if text.chars().count() > max_len {
        return Err(TypeSyntaxError::TooLong { max: max_len });
    }
    reject_comments(grammar, text)?;

    let mut parser = Parser::new(grammar.parser_dialect())
        .with_recursion_limit(RECURSION_LIMIT)
        .try_with_sql(text)
        .map_err(|error| TypeSyntaxError::Invalid(error.to_string()))?;
    let parsed = parser
        .parse_data_type()
        .map_err(|error| TypeSyntaxError::Invalid(error.to_string()))?;
    // Without this, `INT; DROP TABLE x` parses as INT and the rest is
    // spliced into whatever DDL the caller builds.
    if parser.peek_token_ref().token != Token::EOF {
        return Err(TypeSyntaxError::Invalid("unexpected text after the type".to_owned()));
    }
    Ok(ValidatedType {
        text: text.to_owned(),
        shape: shape_of(&parsed),
    })
}

pub(crate) const RECURSION_LIMIT: usize = 64;

/// A comment swallows every clause after it, so a type or expression
/// carrying one cannot be pasted into DDL safely.
pub(crate) fn reject_comment_tokens(grammar: SqlGrammar, text: &str) -> Result<(), ()> {
    let tokens = Tokenizer::new(grammar.parser_dialect(), text)
        .tokenize_with_location()
        .map_err(|_| ())?;
    let has_comment = tokens.iter().any(|token| {
        matches!(
            token.token,
            Token::Whitespace(Whitespace::SingleLineComment { .. } | Whitespace::MultiLineComment(_))
        )
    });
    if has_comment { Err(()) } else { Ok(()) }
}

fn reject_comments(grammar: SqlGrammar, text: &str) -> Result<(), TypeSyntaxError> {
    match reject_comment_tokens(grammar, text) {
        Ok(()) => Ok(()),
        // A tokenizer failure is reported by the parser below with a
        // better message, so only the comment case stops here.
        Err(()) if text.contains("--") || text.contains("/*") => Err(TypeSyntaxError::Comment),
        Err(()) => Ok(()),
    }
}

pub(crate) fn shape_of(parsed: &DataType) -> TypeShape {
    match parsed {
        DataType::TinyInt(width) => TypeShape::TinyIntDisplayWidth {
            width: *width,
            unsigned: false,
        },
        DataType::TinyIntUnsigned(width) => TypeShape::TinyIntDisplayWidth {
            width: *width,
            unsigned: true,
        },
        DataType::IntUnsigned(_)
        | DataType::BigIntUnsigned(_)
        | DataType::SmallIntUnsigned(_)
        | DataType::MediumIntUnsigned(_)
        | DataType::Int2Unsigned(_)
        | DataType::Int4Unsigned(_)
        | DataType::Int8Unsigned(_)
        | DataType::IntegerUnsigned(_)
        | DataType::DecimalUnsigned(_)
        | DataType::DecUnsigned(_)
        | DataType::FloatUnsigned(_)
        | DataType::DoubleUnsigned(_)
        | DataType::DoublePrecisionUnsigned
        | DataType::RealUnsigned
        | DataType::Unsigned
        | DataType::UnsignedInteger
        | DataType::UInt8
        | DataType::UInt16
        | DataType::UInt32
        | DataType::UInt64
        | DataType::UInt128
        | DataType::UInt256 => TypeShape::Named { unsigned: true },
        DataType::Enum(members, _) => TypeShape::Enum {
            members: members.iter().map(enum_member_name).collect(),
        },
        DataType::Set(members) => TypeShape::Set {
            members: members.clone(),
        },
        DataType::Array(_) => TypeShape::Array,
        DataType::Custom(_, _) => TypeShape::Custom,
        _ => TypeShape::Named { unsigned: false },
    }
}

fn enum_member_name(member: &sqlparser::ast::EnumMember) -> String {
    match member {
        sqlparser::ast::EnumMember::Name(name) => name.clone(),
        sqlparser::ast::EnumMember::NamedValue(name, _) => name.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(grammar: SqlGrammar, text: &str) -> Result<ValidatedType, TypeSyntaxError> {
        parse_type(grammar, text, MAX_TYPE_LEN)
    }

    #[test]
    fn parse_type_accepts_engine_spellings() {
        let cases = [
            (SqlGrammar::PostgreSql, "varchar(255)"),
            (SqlGrammar::PostgreSql, "numeric(10, 2)"),
            (SqlGrammar::PostgreSql, "integer[]"),
            (SqlGrammar::PostgreSql, "timestamp with time zone"),
            (SqlGrammar::MySql, "enum('a','b')"),
            (SqlGrammar::MySql, "int(10) unsigned"),
            (SqlGrammar::Sqlite, "DECIMAL(10,2)"),
            (SqlGrammar::MsSql, "nvarchar(max)"),
            (SqlGrammar::ClickHouse, "Nullable(Int64)"),
            (SqlGrammar::ClickHouse, "DateTime64(3, 'UTC')"),
        ];

        for (grammar, text) in cases {
            let parsed = parse(grammar, text).unwrap_or_else(|error| panic!("{grammar:?} {text}: {error}"));
            assert_eq!(parsed.text, text);
        }
    }

    #[test]
    fn parse_type_reports_unsigned_and_arrays() {
        assert_eq!(
            parse(SqlGrammar::MySql, "int(10) unsigned").expect("unsigned").shape,
            TypeShape::Named { unsigned: true }
        );
        assert_eq!(
            parse(SqlGrammar::PostgreSql, "integer[]").expect("array").shape,
            TypeShape::Array
        );
        assert_eq!(
            parse(SqlGrammar::MySql, "tinyint(1)").expect("tinyint").shape,
            TypeShape::TinyIntDisplayWidth {
                width: Some(1),
                unsigned: false
            }
        );
    }

    #[test]
    fn parse_type_keeps_enum_and_set_members() {
        let parsed = parse(SqlGrammar::MySql, "enum('a','b')").expect("enum");
        assert_eq!(
            parsed.shape,
            TypeShape::Enum {
                members: vec!["a".to_owned(), "b".to_owned()]
            }
        );

        let parsed = parse(SqlGrammar::MySql, "set('x','y')").expect("set");
        assert_eq!(
            parsed.shape,
            TypeShape::Set {
                members: vec!["x".to_owned(), "y".to_owned()]
            }
        );
    }

    #[test]
    fn mysql_enum_members_with_quote_and_backslash() {
        let parsed = parse(SqlGrammar::MySql, r"enum('it''s','a\b')").expect("enum");

        let TypeShape::Enum { members } = parsed.shape else {
            panic!("expected an enum");
        };
        assert_eq!(members.len(), 2);
        assert!(members[0].contains("it"), "{members:?}");
    }

    #[test]
    fn parse_type_rejects_trailing_tokens() {
        for text in ["INT; DROP TABLE x", "int)"] {
            let error = parse(SqlGrammar::PostgreSql, text).expect_err(text);
            assert!(matches!(error, TypeSyntaxError::Invalid(_)), "{text}: {error:?}");
        }
    }

    #[test]
    fn parse_type_rejects_comments() {
        for text in ["int -- x", "int /* x */"] {
            let error = parse(SqlGrammar::PostgreSql, text).expect_err(text);
            assert_eq!(error, TypeSyntaxError::Comment, "{text}");
        }
    }

    #[test]
    fn parse_rejects_empty_and_over_length() {
        assert_eq!(parse(SqlGrammar::PostgreSql, "   "), Err(TypeSyntaxError::Empty));
        assert_eq!(
            parse_type(SqlGrammar::PostgreSql, "varchar(255)", 4),
            Err(TypeSyntaxError::TooLong { max: 4 })
        );
    }
}
