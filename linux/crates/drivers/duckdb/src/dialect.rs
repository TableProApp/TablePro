use tablepro_core::column::{ColumnInfo, ColumnKind, ColumnType, ReadForm, SqlExpression};
use tablepro_core::ddl::DdlDialect;
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, SqlDialect,
};
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    CredentialRules, ExpressionSyntaxError, HistoryRecording, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar,
    TypeSyntaxError, classify_for_history, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::Value;

use crate::duck_type::column_type_from_text;
use crate::encode::duck_text;

/// How DuckDB spells SQL.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DuckDbDialect;

impl DuckDbDialect {
    pub fn new() -> Self {
        Self
    }

    pub(crate) fn string_literal(&self, text: &str) -> String {
        let quoted = |piece: &str| format!("'{}'", piece.replace('\'', "''"));
        // A NUL inside quotes would end the literal where DuckDB reads
        // the text as a C string, so each one is joined in with chr(0).
        match text.contains('\0') {
            false => quoted(text),
            true => {
                let pieces: Vec<String> = text.split('\0').map(quoted).collect();
                format!("({})", pieces.join(" || chr(0) || "))
            }
        }
    }
}

impl SqlDialect for DuckDbDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities { exact_row_counts: true }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::DuckDb
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    /// A value DuckDB has no binding for goes as text, cast to the
    /// column's own type, so it is parsed the way the column reads it.
    fn placeholder(&self, _ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let column = match target {
            BindTarget::Pattern => return Ok(Placeholder::bound("?", BoundParam::new(value, ParamType::Text)?)),
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a DuckDB value",
                    found: "a row address",
                });
            }
            BindTarget::Column(column) => column,
        };
        let (value, param_type) = value_param(value, &column.column_type)?;
        let sql = match &column.column_type.catalog {
            Some(catalog) if needs_cast(&column.column_type) => format!("CAST(? AS {})", catalog.cast_target.as_sql()),
            _ => "?".to_owned(),
        };
        Ok(Placeholder::bound(sql, BoundParam::new(value, param_type)?))
    }

    fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            Value::Bool(flag) => Ok(if *flag { "TRUE" } else { "FALSE" }.to_owned()),
            Value::Int(integer) => Ok(integer.to_string()),
            Value::UInt(integer) => Ok(integer.to_string()),
            Value::WideInt(integer) => Ok(integer.to_string()),
            Value::Decimal(decimal) if decimal.is_finite() => Ok(decimal.to_string()),
            // Debug keeps the point or the exponent, so `2.0` stays a
            // DOUBLE instead of reading back as the integer 2.
            Value::Float32(real) if real.is_finite() => Ok(format!("CAST({:?} AS FLOAT)", f64::from(*real))),
            Value::Float64(real) if real.is_finite() => Ok(format!("CAST({real:?} AS DOUBLE)")),
            Value::Float32(real) => Ok(format!("CAST('{}' AS FLOAT)", non_finite(f64::from(*real)))),
            Value::Float64(real) => Ok(format!("CAST('{}' AS DOUBLE)", non_finite(*real))),
            Value::Text(text) => Ok(self.string_literal(text)),
            Value::Bytes(bytes) => {
                let escaped: String = bytes.iter().map(|byte| format!("\\x{byte:02X}")).collect();
                Ok(format!("CAST('{escaped}' AS BLOB)"))
            }
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            Value::Array(_) | Value::Decimal(_) => Err(LiteralError::Unrepresentable {
                found: value.variant_name(),
            }),
            // DuckDB writes a UNION as its member's value alone, and reads
            // that text back as the first member it fits, which may be
            // another one.
            Value::Other(other) if names_union(&other.type_name) || names_union(&column.name) => {
                Err(LiteralError::Unrepresentable {
                    found: "a UNION value",
                })
            }
            other => {
                let text = duck_text(other).ok_or(LiteralError::Unrepresentable {
                    found: other.variant_name(),
                })?;
                let target = column
                    .catalog
                    .as_ref()
                    .map(|catalog| catalog.cast_target.as_sql().to_owned())
                    .or_else(|| type_of(other).map(str::to_owned));
                Ok(match target {
                    Some(target) => format!("CAST({} AS {target})", self.string_literal(&text)),
                    None => self.string_literal(&text),
                })
            }
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

    /// DuckDB's rowid moves when a checkpoint compacts a table, so it
    /// names no row.
    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::DuckDb, text, MAX_TYPE_LEN)?;
        Ok(column_type_from_text(&parsed.text))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::DuckDb, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn history_recording(&self, sql: &str) -> HistoryRecording {
        classify_for_history(SqlGrammar::DuckDb, &CREDENTIAL_RULES, sql)
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(self)
    }

    /// A value Arrow cannot carry whole is read as DuckDB's own text.
    fn projection(&self, column: &ColumnInfo) -> String {
        let name = self.quote_identifier(&column.name);
        match column.column_type.read_form {
            ReadForm::ServerText | ReadForm::ServerNumeric => format!("CAST({name} AS VARCHAR) AS {name}"),
            ReadForm::Native => name,
        }
    }

    /// DuckDB casts nothing to text on its own for LIKE.
    fn text_operand(&self, column: &ColumnInfo) -> Option<String> {
        match column.column_type.kind {
            ColumnKind::Text { .. } | ColumnKind::Json { .. } => None,
            _ => Some(format!("CAST({} AS VARCHAR)", self.quote_identifier(&column.name))),
        }
    }

    /// DuckDB's indexes do not order a scan, so ORDER BY the key sorts
    /// every row in memory, while `preserve_insertion_order`, on by
    /// default, returns a plain scan in storage order.
    fn key_order_sorts_the_table(&self) -> bool {
        true
    }
}

/// Whether a value for the column goes as text DuckDB has to cast: a
/// column whose type has no binding of its own. An ENUM label bound as
/// VARCHAR would compare as text, so a key read past `'sad'` in
/// `ENUM('sad', 'ok', 'happy')` would find nothing after it.
fn needs_cast(column: &ColumnType) -> bool {
    !matches!(
        column.kind,
        ColumnKind::Bool(_)
            | ColumnKind::Integer(_)
            | ColumnKind::Float(_)
            | ColumnKind::Text { .. }
            | ColumnKind::Bytes { .. }
            | ColumnKind::Date
            | ColumnKind::Interval
    )
}

/// The parameter a value takes for a column.
fn value_param(value: Value, column: &ColumnType) -> Result<(Value, ParamType), BindError> {
    if let Value::Other(other) = value {
        let target = column.catalog.as_ref().map_or_else(
            || tablepro_core::column::SqlTypeExpr::from_catalog_text(column.name.clone()),
            |catalog| catalog.cast_target.clone(),
        );
        return Ok((Value::Text(other.text), ParamType::ServerText(target)));
    }
    let param_type = match &value {
        Value::Null | Value::Text(_) => ParamType::Text,
        Value::Bool(_) => ParamType::Bool,
        Value::Int(_) => ParamType::Int64,
        Value::UInt(_) => ParamType::UInt64,
        Value::WideInt(_) | Value::Decimal(_) => ParamType::Decimal,
        Value::Float32(_) => ParamType::Float32,
        Value::Float64(_) => ParamType::Float64,
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
                expected: "a DuckDB value",
                found: "Array",
            });
        }
    };
    Ok((value, param_type))
}

/// Whether a DuckDB type name holds a UNION, at any depth.
fn names_union(type_name: &str) -> bool {
    type_name.to_ascii_uppercase().contains("UNION(")
}

/// The type a literal of `value` is cast to when the column names none.
fn type_of(value: &Value) -> Option<&'static str> {
    Some(match value {
        Value::Uuid(_) => "UUID",
        Value::Json(_) => "JSON",
        Value::Date(_) => "DATE",
        Value::Time(_) => "TIME",
        Value::TimeTz(_) => "TIMETZ",
        Value::Timestamp(_) => "TIMESTAMP",
        Value::TimestampTz(_) => "TIMESTAMPTZ",
        Value::Interval(_) => "INTERVAL",
        Value::Bits(_) => "BIT",
        _ => return None,
    })
}

fn non_finite(real: f64) -> &'static str {
    match (real.is_nan(), real.is_sign_negative()) {
        (true, _) => "nan",
        (false, true) => "-inf",
        (false, false) => "inf",
    }
}

/// The settings that hold a credential, and PRAGMA's Parquet key.
const SECRET_SETTINGS: &[&str] = &[
    "s3_access_key_id",
    "s3_secret_access_key",
    "s3_session_token",
    "azure_storage_connection_string",
    "azure_account_key",
    "azure_proxy_password",
    "motherduck_token",
    "http_proxy",
    "http_proxy_password",
    "hf_token",
    "add_parquet_key",
];

/// Statements and calls whose text can hold a secret: a stored secret,
/// a setting that is one, and the connection strings of the scanners
/// that reach other databases. ATTACH names any database, an encrypted
/// file's key or a server's login among them.
const CREDENTIAL_RULES: CredentialRules = CredentialRules {
    statement_prefixes: &[
        &["CREATE", "SECRET"],
        &["CREATE", "PERSISTENT", "SECRET"],
        &["CREATE", "TEMPORARY", "SECRET"],
        &["CREATE", "TEMP", "SECRET"],
        &["ATTACH"],
    ],
    // A setting is set by SET or by PRAGMA, and PRAGMA also adds a
    // Parquet key.
    conditional_prefixes: &[(&["SET"], SECRET_SETTINGS), (&["PRAGMA"], SECRET_SETTINGS)],
    carriers: &[
        "postgres_attach",
        "postgres_scan",
        "postgres_scan_pushdown",
        "postgres_query",
        "postgres_execute",
        "mysql_query",
        "mysql_execute",
        "add_parquet_key",
    ],
};

#[cfg(test)]
mod tests {
    use tablepro_core::column::{CatalogType, ColumnDefault, SqlTypeExpr, TextLength};
    use tablepro_core::sql_syntax::WithholdReason;

    use super::*;

    fn column(declaration: &str) -> ColumnInfo {
        ColumnInfo {
            name: "v".to_owned(),
            column_type: column_type_from_text(declaration),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_value_with_no_binding_is_cast_to_its_column() {
        let dialect = DuckDbDialect;
        let decimal = column("DECIMAL(38,10)");
        let integer = column("INTEGER");

        let bound = dialect
            .placeholder(0, Value::Decimal("1.5".parse().unwrap()), BindTarget::Column(&decimal))
            .unwrap();
        let plain = dialect
            .placeholder(0, Value::Int(1), BindTarget::Column(&integer))
            .unwrap();

        assert_eq!(bound.sql, "CAST(? AS DECIMAL(38,10))");
        assert_eq!(plain.sql, "?");
    }

    #[test]
    fn an_enum_label_is_cast_to_its_column() {
        let mood = column("ENUM('sad', 'ok', 'happy')");

        let bound = DuckDbDialect
            .placeholder(0, Value::Text("sad".to_owned()), BindTarget::Column(&mood))
            .unwrap();

        assert_eq!(bound.sql, "CAST(? AS ENUM('sad', 'ok', 'happy'))");
    }

    #[test]
    fn a_union_value_has_no_literal() {
        let dialect = DuckDbDialect;
        let union = column("UNION(n INTEGER, s VARCHAR)");
        let list = column("UNION(n INTEGER, s VARCHAR)[]");
        let value = |type_name: &str| {
            Value::Other(Box::new(tablepro_core::value::OtherValue {
                type_name: type_name.to_owned(),
                text: "2".to_owned(),
            }))
        };

        assert!(dialect.literal(&value("UNION(n INTEGER, s VARCHAR)"), &union.column_type).is_err());
        assert!(dialect.literal(&value("UNION(n INTEGER, s VARCHAR)[]"), &list.column_type).is_err());
        assert!(dialect.literal(&value("INTEGER[]"), &column("INTEGER[]").column_type).is_ok());
    }

    #[test]
    fn literals_are_spelled_as_duckdb_reads_them() {
        let dialect = DuckDbDialect;
        let text = ColumnType {
            name: "VARCHAR".to_owned(),
            kind: ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            catalog: Some(CatalogType {
                declaration: SqlTypeExpr::from_catalog_text("VARCHAR"),
                cast_target: SqlTypeExpr::from_catalog_text("VARCHAR"),
            }),
            dynamic_storage: false,
            read_form: ReadForm::Native,
        };

        assert_eq!(
            dialect.literal(&Value::Text("it's".to_owned()), &text).unwrap(),
            "'it''s'"
        );
        assert_eq!(
            dialect.literal(&Value::Text("a\0b".to_owned()), &text).unwrap(),
            "('a' || chr(0) || 'b')"
        );
        assert_eq!(
            dialect.literal(&Value::Bytes(vec![0xde, 0x01]), &text).unwrap(),
            "CAST('\\xDE\\x01' AS BLOB)"
        );
        assert_eq!(
            dialect.literal(&Value::Float64(f64::NAN), &text).unwrap(),
            "CAST('nan' AS DOUBLE)"
        );
        assert_eq!(dialect.literal(&Value::Bool(true), &text).unwrap(), "TRUE");
    }

    #[test]
    fn a_nested_column_reads_as_duckdb_text() {
        assert_eq!(
            DuckDbDialect.projection(&column("INTEGER[]")),
            "CAST(\"v\" AS VARCHAR) AS \"v\""
        );
        assert_eq!(DuckDbDialect.projection(&column("INTEGER")), "\"v\"");
    }

    #[test]
    fn secrets_and_connection_strings_stay_out_of_the_history() {
        let withheld = HistoryRecording::Withhold(WithholdReason::CredentialStatement);
        for sql in [
            "CREATE SECRET s (TYPE s3, KEY_ID 'k', SECRET 'v')",
            "CREATE OR REPLACE PERSISTENT SECRET s (TYPE s3, KEY_ID 'k', SECRET 'v')",
            "ATTACH 'host=db user=u password=p' AS pg (TYPE postgres)",
            "SET s3_secret_access_key = 'v'",
            "SET GLOBAL motherduck_token = 'v'",
            "SELECT * FROM postgres_scan('host=db password=p', 'public', 't')",
            "PRAGMA add_parquet_key('k', '0123456789112345')",
            "PRAGMA http_proxy_password = 'v'",
            "PRAGMA s3_secret_access_key='v'",
            "SET http_proxy = 'http://u:p@proxy:3128'",
        ] {
            assert_eq!(DuckDbDialect.history_recording(sql), withheld, "{sql}");
        }
        assert_eq!(
            tablepro_test_support::history_cases::unrecorded_plain_statements(&DuckDbDialect),
            Vec::<&str>::new()
        );
    }
}
