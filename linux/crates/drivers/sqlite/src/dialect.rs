use tablepro_core::column::{ColumnInfo, ColumnKind, ColumnType, SqlExpression};
use tablepro_core::ddl::{DdlCapabilities, DdlDialect};
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LikeCase, LikeForm, LiteralError, Placeholder,
    SqlDialect,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::Value;

use crate::catalog::{SqliteVersion, declared_column_type};

/// How SQLite spells SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SqliteDialect {
    version: SqliteVersion,
}

/// What the structure tab can change on SQLite without rebuilding the
/// table. Everything ALTER TABLE cannot do is off until the rebuild
/// plans exist.
static DDL: SqliteDdl = SqliteDdl {
    capabilities: DdlCapabilities {
        create_table: true,
        rename_table: true,
        add_column: true,
        drop_column: true,
        rename_column: true,
        alter_column_type: false,
        alter_column_nullability: false,
        nullability_switch: false,
        alter_column_default: false,
        alter_primary_key: false,
        alter_auto_increment: false,
        create_index: true,
        drop_index: true,
        expression_index_keys: true,
        partial_indexes: true,
        add_foreign_key: false,
        drop_foreign_key: false,
        drop_table_cascade: false,
    },
};

#[derive(Debug)]
struct SqliteDdl {
    capabilities: DdlCapabilities,
}

impl DdlDialect for SqliteDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }
}

impl SqliteDialect {
    pub fn new(version: SqliteVersion) -> Self {
        Self { version }
    }

    pub fn version(&self) -> SqliteVersion {
        self.version
    }
}

impl SqlDialect for SqliteDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities { exact_row_counts: true }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::Sqlite
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    fn placeholder(&self, _ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let (value, param_type) = match target {
            BindTarget::Pattern => (value, ParamType::Text),
            BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid) => (value, ParamType::Int64),
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a SQLite rowid",
                    found: "another engine's row address",
                });
            }
            BindTarget::Column(column) => column_param(value, column)?,
        };
        Ok(Placeholder::bound("?", BoundParam::new(value, param_type)?))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            Value::Bool(flag) => Ok(if *flag { "1" } else { "0" }.to_owned()),
            Value::Int(integer) => Ok(integer.to_string()),
            Value::UInt(integer) => Ok(integer.to_string()),
            Value::WideInt(integer) => Ok(integer.to_string()),
            Value::Decimal(decimal) if decimal.is_finite() => Ok(decimal.to_string()),
            // Debug keeps the decimal point or exponent, so `2.0` stays
            // a real instead of reading back as the integer 2.
            Value::Float32(real) if real.is_finite() => Ok(format!("{:?}", f64::from(*real))),
            Value::Float64(real) if real.is_finite() => Ok(format!("{real:?}")),
            Value::Bytes(bytes) => Ok(format!("X'{}'", tablepro_core::hex::encode_lower(bytes))),
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            Value::Array(_) | Value::Decimal(_) | Value::Float32(_) | Value::Float64(_) => {
                Err(LiteralError::Unrepresentable {
                    found: value.variant_name(),
                })
            }
            // Text and the temporal values, stored as the ISO text
            // SQLite's date functions read.
            other => match value_to_text(other) {
                Some(text) => Ok(text_literal(&text)),
                None => Ok("NULL".to_owned()),
            },
        }
    }

    fn escape_like_text(&self, text: &str) -> String {
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if matches!(character, '!' | '%' | '_') {
                escaped.push('!');
            }
            escaped.push(character);
        }
        escaped
    }

    /// LIKE ignores ASCII case already, but only for LIKE: LOWER() on
    /// both sides keeps an insensitive filter insensitive whatever
    /// `case_sensitive_like` a session set.
    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let (left, right) = match form.case {
            LikeCase::Insensitive => (format!("LOWER({column_sql})"), format!("LOWER({pattern_sql})")),
            LikeCase::EngineDefault => (column_sql.to_owned(), pattern_sql.to_owned()),
        };
        let operator = if form.negated { "NOT LIKE" } else { "LIKE" };
        match form.escaped {
            true => format!("{left} {operator} {right} ESCAPE '!'"),
            false => format!("{left} {operator} {right}"),
        }
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        match order_by.map(str::trim).filter(|order| !order.is_empty()) {
            Some(order) => format!(" ORDER BY {order} LIMIT {limit} OFFSET {offset}"),
            None => format!(" LIMIT {limit} OFFSET {offset}"),
        }
    }

    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        format!(
            "({}) {} ({})",
            key_sql.join(", "),
            direction.comparison(),
            markers.join(", ")
        )
    }

    fn engine_row_id(&self, id: EngineRowId) -> Option<String> {
        match id {
            EngineRowId::SqliteRowid => Some(format!(
                "{} AS {}",
                self.engine_row_id_column(EngineRowIdPart::SqliteRowid)?,
                self.quote_identifier(EngineRowIdPart::SqliteRowid.projection_alias())
            )),
            EngineRowId::PostgresCtid | EngineRowId::PostgresTableoidCtid => None,
        }
    }

    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
        match part {
            EngineRowIdPart::SqliteRowid => Some(self.quote_identifier("rowid")),
            EngineRowIdPart::PostgresCtid | EngineRowIdPart::PostgresTableOid | EngineRowIdPart::PostgresXmin => None,
        }
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::Sqlite, text, MAX_TYPE_LEN)?;
        // A draft column has no table yet, so it reads as it would in
        // an ordinary table, the only kind the app creates.
        Ok(declared_column_type(&parsed.text, false))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::Sqlite, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(&DDL)
    }
}

/// SQLite ends SQL text at the first NUL, wherever it stands, so a NUL
/// inside quotes would cut the literal short. Each one is joined in
/// with `char(0)` instead.
fn text_literal(text: &str) -> String {
    let quoted = |piece: &str| format!("'{}'", piece.replace('\'', "''"));
    match text.contains('\0') {
        false => quoted(text),
        true => {
            let pieces: Vec<String> = text.split('\0').map(quoted).collect();
            format!("({})", pieces.join(" || char(0) || "))
        }
    }
}

/// The parameter a value takes for a column.
///
/// A column of an ordinary table stores whatever class it is given, so
/// the value names its own type. A STRICT column takes only its
/// declared class, which is checked here before the server refuses it.
fn column_param(value: Value, column: &ColumnInfo) -> Result<(Value, ParamType), BindError> {
    if !column.column_type.dynamic_storage {
        let strict = match &column.column_type.kind {
            ColumnKind::Integer(_) => Some(ParamType::Int64),
            ColumnKind::Float(_) => Some(ParamType::Float64),
            ColumnKind::Text { .. } => Some(ParamType::Text),
            ColumnKind::Bytes { .. } => Some(ParamType::Bytes),
            _ => None,
        };
        if let Some(param_type) = strict {
            return Ok((value, param_type));
        }
    }
    value_param(value)
}

fn value_param(value: Value) -> Result<(Value, ParamType), BindError> {
    // A value only the server could name travels as the text it was
    // typed as, which is what SQLite stores for it anyway.
    if let Value::Other(other) = value {
        return Ok((Value::Text(other.text), ParamType::Text));
    }
    let param_type = match &value {
        Value::Null | Value::Text(_) => ParamType::Text,
        Value::Bool(_) => ParamType::Bool,
        Value::Int(_) | Value::UInt(_) => ParamType::Int64,
        Value::WideInt(_) | Value::Decimal(_) => ParamType::Decimal,
        Value::Float32(_) | Value::Float64(_) => ParamType::Float64,
        Value::Bytes(_) => ParamType::Bytes,
        Value::Bits(_) => ParamType::Bits,
        Value::Uuid(_) => ParamType::Uuid,
        Value::Json(_) => ParamType::Json,
        Value::Date(_) => ParamType::Date,
        Value::Time(_) => ParamType::Time,
        Value::TimeTz(_) => ParamType::TimeTz,
        Value::Timestamp(_) => ParamType::Timestamp,
        Value::TimestampTz(_) => ParamType::TimestampTz,
        Value::Interval(_) => ParamType::Interval,
        Value::Other(_) | Value::Undecodable(_) => ParamType::Text,
        Value::Array(_) => {
            return Err(BindError::Unrepresentable {
                expected: "a SQLite value",
                found: "Array",
            });
        }
    };
    Ok((value, param_type))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{BoolStorage, ColumnDefault, ReadForm, TextLength};
    use tablepro_core::value::OtherValue;

    use super::*;

    fn dialect() -> SqliteDialect {
        SqliteDialect::new(SqliteVersion::new(3, 46, 1))
    }

    fn column(declared: &str, strict: bool) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: declared_column_type(declared, strict),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn sqlite_rowid_placeholder_is_a_question_mark() {
        let placeholder = dialect()
            .placeholder(3, Value::Int(42), BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid))
            .unwrap();

        assert_eq!(placeholder.sql, "?");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::Int64)
        );
        assert_eq!(
            dialect().engine_row_id(EngineRowId::SqliteRowid),
            Some(r#""rowid" AS "__tablepro_row_id""#.to_owned())
        );
        assert!(
            dialect()
                .placeholder(0, Value::Int(1), BindTarget::EngineRowId(EngineRowIdPart::PostgresCtid))
                .is_err()
        );
    }

    #[test]
    fn row_value_after_compares_the_whole_key() {
        let keys = ["\"a\"".to_owned(), "\"b\"".to_owned()];
        let markers = ["?".to_owned(), "?".to_owned()];

        assert_eq!(
            dialect().row_value_after(&keys, &markers, KeysetDirection::After),
            "(\"a\", \"b\") > (?, ?)"
        );
        assert_eq!(
            dialect().row_value_after(&keys, &markers, KeysetDirection::Before),
            "(\"a\", \"b\") < (?, ?)"
        );
    }

    #[test]
    fn an_ordinary_column_binds_the_class_the_value_has() {
        let integer = column("INTEGER", false);

        let text = dialect()
            .placeholder(0, Value::Text("n/a".to_owned()), BindTarget::Column(&integer))
            .unwrap();
        let typed_other = dialect()
            .placeholder(
                0,
                Value::Other(Box::new(OtherValue {
                    type_name: "STRING".to_owned(),
                    text: "kept".to_owned(),
                })),
                BindTarget::Column(&column("STRING", false)),
            )
            .unwrap();

        assert_eq!(
            text.param.map(|param| param.value().clone()),
            Some(Value::Text("n/a".to_owned()))
        );
        assert_eq!(
            typed_other.param.map(|param| param.value().clone()),
            Some(Value::Text("kept".to_owned()))
        );
    }

    #[test]
    fn a_strict_column_refuses_another_class_before_the_server_does() {
        let strict_integer = column("INTEGER", true);

        let refused = dialect().placeholder(0, Value::Text("7".to_owned()), BindTarget::Column(&strict_integer));

        assert_eq!(
            refused,
            Err(BindError::ValueTypeMismatch {
                expected: "Int64",
                found: "Text"
            })
        );
    }

    #[test]
    fn like_escapes_with_bang_and_lowers_both_sides_when_insensitive() {
        assert_eq!(dialect().escape_like_text("50%_!"), "50!%!_!!");
        assert_eq!(
            dialect().like_predicate("\"a\"", "?", LikeForm::contains()),
            "\"a\" LIKE ? ESCAPE '!'"
        );
        assert_eq!(
            dialect().like_predicate("\"a\"", "?", LikeForm::insensitive(true)),
            "LOWER(\"a\") NOT LIKE LOWER(?)"
        );
    }

    #[test]
    fn literals_keep_their_storage_class() {
        let text = ColumnType::untyped_text("TEXT");
        let cases = [
            (Value::Null, "NULL"),
            (Value::Bool(true), "1"),
            (Value::Int(-3), "-3"),
            (Value::Float64(2.0), "2.0"),
            (Value::Float64(1e300), "1e300"),
            (Value::Bytes(vec![0xde, 0xad]), "X'dead'"),
            (Value::Text("it's".to_owned()), "'it''s'"),
        ];
        for (value, expected) in cases {
            assert_eq!(dialect().literal(&value, &text).as_deref(), Ok(expected), "{value:?}");
        }
        assert!(dialect().literal(&Value::Float64(f64::NAN), &text).is_err());
    }

    #[test]
    fn a_nul_in_text_is_joined_in_rather_than_quoted() {
        let text = ColumnType::untyped_text("TEXT");

        assert_eq!(
            dialect().literal(&Value::Text("a\0b'c".to_owned()), &text).as_deref(),
            Ok("('a' || char(0) || 'b''c')")
        );
        assert_eq!(
            dialect().literal(&Value::Text("\0".to_owned()), &text).as_deref(),
            Ok("('' || char(0) || '')")
        );
    }

    #[test]
    fn literal_round_trips_through_the_sqlite_parser() {
        use sqlparser::dialect::SQLiteDialect;
        use sqlparser::tokenizer::{Token, Tokenizer};

        let text = ColumnType::untyped_text("TEXT");
        let cases = [
            (
                Value::Text("a;b'c".to_owned()),
                Token::SingleQuotedString("a;b'c".to_owned()),
            ),
            (Value::Float64(0.5), Token::Number("0.5".to_owned(), false)),
            (Value::Int(12), Token::Number("12".to_owned(), false)),
            (
                Value::Bytes(vec![0xde, 0xad]),
                Token::HexStringLiteral("dead".to_owned()),
            ),
        ];
        for (value, expected) in cases {
            let literal = dialect().literal(&value, &text).unwrap();
            let tokens = Tokenizer::new(&SQLiteDialect {}, &literal).tokenize().unwrap();
            assert_eq!(tokens, [expected], "{literal}");
        }
    }

    #[test]
    fn a_draft_type_reads_as_in_an_ordinary_table() {
        let parsed = dialect().parse_type("boolean").unwrap();

        assert_eq!(parsed.kind, ColumnKind::Bool(BoolStorage::Integer));
        assert!(parsed.dynamic_storage);
        assert_eq!(parsed.read_form, ReadForm::Native);
        assert_eq!(
            dialect().parse_type("varchar(20)").map(|parsed| parsed.kind),
            Ok(ColumnKind::Text {
                length: TextLength::Unbounded
            })
        );
        assert!(dialect().ddl().is_some_and(|ddl| ddl.capabilities().partial_indexes));
    }
}
