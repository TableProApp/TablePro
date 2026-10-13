use tablepro_core::ServerInfo;
use tablepro_core::column::{
    BoolStorage, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerWidth, SqlExpression, TemporalZone, TextLength,
};
use tablepro_core::ddl::DdlDialect;
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LikeCase, LikeForm, LiteralError, Placeholder,
    SqlDialect,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{EngineRowId, EngineRowIdPart, TableRef};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

use crate::clickhouse_type::ClickHouseType;
use crate::param_value::param_name;

/// The characters ClickHouse's lexer reads a backslash before, inside a
/// quoted string or a quoted identifier alike. The same set as the
/// clickhouse crate's own escaper, which a test holds this to.
const ESCAPED: [char; 5] = ['\\', '\'', '`', '\t', '\n'];

/// How ClickHouse spells the SQL the app generates.
///
/// Values travel as server-side `{pN:Type}` parameters, typed by the
/// column's own declaration, so the server parses each one exactly as
/// the column would: a DateTime64 in the column's zone, a Decimal(76,
/// 20) digit for digit, and a key that is not UTF-8 byte for byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClickHouseDialect {
    major: u32,
    minor: u32,
}

impl ClickHouseDialect {
    pub fn new(server: &ServerInfo) -> Self {
        Self {
            major: server.major,
            minor: server.minor,
        }
    }

    /// The server's major and minor version, for SQL that changed
    /// between releases.
    pub fn version(&self) -> (u32, u32) {
        (self.major, self.minor)
    }
}

impl SqlDialect for ClickHouseDialect {
    fn capabilities(&self) -> DialectCapabilities {
        // A mutation reports nothing useful about how many rows it
        // touched, so a write proves itself with a probe instead.
        DialectCapabilities {
            exact_row_counts: false,
        }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::ClickHouse
    }

    fn quote_identifier(&self, name: &str) -> String {
        let mut quoted = String::with_capacity(name.len() + 2);
        quoted.push('`');
        escape_into(name, &mut quoted);
        quoted.push('`');
        quoted
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        // A parameter typed as the column refuses `\N` unless the type is
        // Nullable, and the literal means NULL to every type.
        if value.is_null() {
            return Ok(Placeholder::inline("NULL"));
        }
        let (param_type, type_sql) = match target {
            BindTarget::Pattern => (ParamType::Text, "String".to_owned()),
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a ClickHouse value",
                    found: "an engine row address",
                });
            }
            BindTarget::Column(column) => (column_param_type(column, &value)?, bind_type(column)?),
        };
        let param = BoundParam::new(value, param_type)?;
        Ok(Placeholder::bound(
            format!("{{{}:{type_sql}}}", param_name(ordinal)),
            param,
        ))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        literal(value)
    }

    fn escape_like_text(&self, text: &str) -> String {
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if matches!(character, '\\' | '%' | '_') {
                escaped.push('\\');
            }
            escaped.push(character);
        }
        escaped
    }

    /// ClickHouse reads a backslash in a pattern as the escape, and its
    /// ESCAPE clause is too new to rely on, so none is written.
    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let operator = match (form.negated, form.case) {
            (false, LikeCase::EngineDefault) => "LIKE",
            (true, LikeCase::EngineDefault) => "NOT LIKE",
            (false, LikeCase::Insensitive) => "ILIKE",
            (true, LikeCase::Insensitive) => "NOT ILIKE",
        };
        format!("{column_sql} {operator} {pattern_sql}")
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

    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::ClickHouse, text, MAX_TYPE_LEN)?;
        Ok(ClickHouseType::parse(&parsed.text).column_type)
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::ClickHouse, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(self)
    }

    /// The column alone: the FROM names the table as `db.table`, which a
    /// `table.column` sort would not match.
    fn sort_expression(&self, _table: &TableRef, column: &ColumnInfo) -> String {
        self.quote_identifier(&column.name)
    }

    fn count_all(&self) -> &'static str {
        "count()"
    }

    /// Standard UPDATE arrived only in 25.7; the mutation spelling works
    /// on every release.
    fn update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        format!("ALTER TABLE {table_sql} UPDATE {assignments_sql} WHERE {predicate_sql}")
    }

    fn delete_statement(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!("ALTER TABLE {table_sql} DELETE WHERE {predicate_sql}")
    }

    /// ClickHouse has no spelling for a row of nothing but defaults.
    fn insert_default_row(&self, _table_sql: &str) -> Option<String> {
        None
    }

    /// No FINAL, so unmerged duplicates of a sorting key count.
    fn key_probe(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!("SELECT count() FROM (SELECT 1 FROM {table_sql} WHERE {predicate_sql} LIMIT 2)")
    }
}

fn escape_into(text: &str, out: &mut String) {
    for character in text.chars() {
        if ESCAPED.contains(&character) {
            out.push('\\');
        }
        out.push(character);
    }
}

/// The type a column's value is bound as, from the catalogue: guessing
/// from the display name could pick the wrong one.
fn bind_type(column: &ColumnInfo) -> Result<String, BindError> {
    column
        .column_type
        .catalog
        .as_ref()
        .map(|catalog| catalog.cast_target.as_sql().to_owned())
        .ok_or_else(|| BindError::MissingCatalogType {
            column: column.name.clone(),
        })
}

/// What a value is checked against before it is bound. The server parses
/// the text as the column's own type either way; this catches a value
/// of the wrong shape before it reaches the server.
fn column_param_type(column: &ColumnInfo, value: &Value) -> Result<ParamType, BindError> {
    let column_type = &column.column_type;
    Ok(match &column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => ParamType::Bool,
        ColumnKind::Bool(BoolStorage::Integer) => ParamType::Int64,
        // An edit narrows a number to the smallest variant that holds
        // it, so an unsigned 64-bit column can receive either.
        ColumnKind::Integer(kind) => match kind.width {
            IntegerWidth::W128 | IntegerWidth::W256 => ParamType::Decimal,
            _ => ParamType::Int64,
        },
        ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => ParamType::Decimal,
        ColumnKind::Float(FloatWidth::F32) => ParamType::Float32,
        ColumnKind::Float(FloatWidth::F64) => ParamType::Float64,
        // A String that is not UTF-8 was read as bytes, and is written back
        // as those bytes so a key built from it matches the row.
        ColumnKind::Text { .. } if matches!(value, Value::Bytes(_)) => ParamType::Bytes,
        ColumnKind::Text {
            length: TextLength::Fixed(_),
        } => ParamType::FixedText,
        ColumnKind::Text { .. } => ParamType::Text,
        ColumnKind::Bytes { .. } => ParamType::Bytes,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time { .. } => ParamType::Time,
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => ParamType::TimestampTz,
        ColumnKind::Timestamp { .. } => ParamType::Timestamp,
        ColumnKind::Json { binary: false } => ParamType::Json,
        ColumnKind::Json { binary: true } => ParamType::JsonBinary,
        ColumnKind::Enum { .. }
        | ColumnKind::Network(_)
        | ColumnKind::Xml
        | ColumnKind::Spatial
        | ColumnKind::Variant
        | ColumnKind::Composite
        | ColumnKind::Array { .. }
        | ColumnKind::Interval
        | ColumnKind::BitString { .. }
        | ColumnKind::Other => ParamType::ServerText(
            column_type
                .catalog
                .as_ref()
                .map(|catalog| catalog.cast_target.clone())
                .ok_or_else(|| BindError::MissingCatalogType {
                    column: column.name.clone(),
                })?,
        ),
    })
}

fn literal(value: &Value) -> Result<String, LiteralError> {
    Ok(match value {
        Value::Null => "NULL".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Int(int) => int.to_string(),
        Value::UInt(int) => int.to_string(),
        Value::WideInt(int) => int.to_string(),
        Value::Float32(float) => float_literal(f64::from(*float)).unwrap_or_else(|| float.to_string()),
        Value::Float64(float) => float_literal(*float).unwrap_or_else(|| float.to_string()),
        Value::Decimal(decimal) if decimal.is_finite() => decimal.to_string(),
        Value::Bytes(bytes) => unhex(bytes),
        Value::Text(text)
            if text
                .chars()
                .any(|character| character.is_control() && !ESCAPED.contains(&character)) =>
        {
            unhex(text.as_bytes())
        }
        Value::Array(values) => {
            let items = values.iter().map(literal).collect::<Result<Vec<_>, _>>()?;
            format!("[{}]", items.join(", "))
        }
        Value::Date(Temporal::Infinity | Temporal::NegInfinity)
        | Value::Timestamp(Temporal::Infinity | Temporal::NegInfinity)
        | Value::TimestampTz(Temporal::Infinity | Temporal::NegInfinity) => {
            return Err(LiteralError::Unrepresentable {
                found: value.variant_name(),
            });
        }
        Value::Undecodable(undecodable) => {
            return Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            });
        }
        Value::Other(other) => quoted(&other.text),
        other => match value_to_text(other) {
            Some(text) => quoted(&text),
            None => {
                return Err(LiteralError::Unrepresentable {
                    found: other.variant_name(),
                });
            }
        },
    })
}

/// A string literal with the crate's escape set, so it reads the same
/// whatever it holds.
fn quoted(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('\'');
    escape_into(text, &mut quoted);
    quoted.push('\'');
    quoted
}

/// Bytes, and text with a control character the escape set does not
/// cover, written as hex so no byte depends on how a string is lexed.
fn unhex(bytes: &[u8]) -> String {
    format!("unhex('{}')", tablepro_core::hex::encode_lower(bytes))
}

/// The words ClickHouse uses for the non-finite floats.
fn float_literal(value: f64) -> Option<String> {
    if value.is_nan() {
        return Some("nan".to_owned());
    }
    if value.is_infinite() {
        return Some(if value.is_sign_negative() { "-inf" } else { "inf" }.to_owned());
    }
    None
}

#[cfg(test)]
mod tests {
    use clickhouse::sql::Identifier;
    use tablepro_core::column::{ColumnDefault, IntegerKind};

    use super::*;

    fn dialect() -> ClickHouseDialect {
        ClickHouseDialect::new(&ServerInfo::new("ClickHouse", "25.8.1.1", 25, 8, 1))
    }

    fn column(type_text: &str) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: ClickHouseType::parse(type_text).column_type,
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn bind(ordinal: usize, value: Value, type_text: &str) -> Result<Placeholder, BindError> {
        dialect().placeholder(ordinal, value, BindTarget::Column(&column(type_text)))
    }

    /// What the clickhouse crate itself writes for an identifier.
    fn crate_identifier(name: &str) -> String {
        clickhouse::Client::default()
            .query("?")
            .bind(Identifier(name))
            .sql_display()
            .to_string()
    }

    #[test]
    fn identifiers_quote_exactly_as_the_crate_does() {
        for name in [
            "plain",
            "a`b",
            r"t\` UNION ALL SELECT 42 --",
            "it's",
            "tab\there",
            "line\nbreak",
            "trailing\\",
            "naïve ✓",
        ] {
            assert_eq!(dialect().quote_identifier(name), crate_identifier(name), "{name:?}");
        }
    }

    #[test]
    fn placeholders_name_the_parameter_and_the_columns_type() {
        let stamp = bind(0, Value::Text("x".to_owned()), "DateTime64(3, 'UTC')");
        assert!(matches!(stamp, Err(BindError::ValueTypeMismatch { .. })));

        let when = chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
            .and_then(|date| date.and_hms_milli_opt(8, 30, 0, 123))
            .expect("a timestamp");
        let stamp = bind(2, Value::Timestamp(Temporal::Finite(when)), "DateTime64(3, 'UTC')").expect("a timestamp");
        assert_eq!(stamp.sql, "{p2:DateTime64(3, 'UTC')}");

        let low = bind(0, Value::Text("a".to_owned()), "LowCardinality(Nullable(String))").expect("a string");
        assert_eq!(low.sql, "{p0:String}");

        let wide = bind(1, Value::UInt(7), "UInt64").expect("an unsigned value");
        assert_eq!(wide.sql, "{p1:UInt64}");
        assert_eq!(wide.param.as_ref().map(BoundParam::param_type), Some(&ParamType::Int64));
    }

    #[test]
    fn a_string_that_is_not_utf8_binds_as_its_bytes() {
        let placeholder = bind(0, Value::Bytes(vec![0xff, 0x41]), "String").expect("bytes for a String");

        assert_eq!(placeholder.sql, "{p0:String}");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::Bytes)
        );
    }

    #[test]
    fn a_null_is_the_literal_and_binds_nothing() {
        let placeholder = bind(3, Value::Null, "Int32").expect("a null");

        assert_eq!(placeholder, Placeholder::inline("NULL"));
    }

    #[test]
    fn an_engine_row_address_has_no_clickhouse_form() {
        let refused = dialect().placeholder(0, Value::Int(1), BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid));

        assert!(matches!(refused, Err(BindError::Unrepresentable { .. })));
        assert_eq!(dialect().engine_row_id_column(EngineRowIdPart::PostgresCtid), None);
    }

    #[test]
    fn a_pattern_binds_as_a_string() {
        let placeholder = dialect()
            .placeholder(4, Value::Text("50\\%".to_owned()), BindTarget::Pattern)
            .expect("a pattern");

        assert_eq!(placeholder.sql, "{p4:String}");
    }

    #[test]
    fn literals_escape_and_fall_back_to_hex() {
        assert_eq!(
            literal(&Value::Text("it's \\ ok".to_owned())),
            Ok(r"'it\'s \\ ok'".to_owned())
        );
        assert_eq!(literal(&Value::Bytes(vec![0x00, 0xff])), Ok("unhex('00ff')".to_owned()));
        assert_eq!(
            literal(&Value::Text("bell\u{7}".to_owned())),
            Ok("unhex('62656c6c07')".to_owned())
        );
        assert_eq!(literal(&Value::Float64(f64::NEG_INFINITY)), Ok("-inf".to_owned()));
        assert_eq!(
            literal(&Value::Array(vec![Value::Int(1), Value::Text("a".to_owned())])),
            Ok("[1, 'a']".to_owned())
        );
    }

    #[test]
    fn like_escapes_with_backslash_and_writes_no_escape_clause() {
        let dialect = dialect();

        assert_eq!(dialect.escape_like_text("a\\%_"), "a\\\\\\%\\_");
        assert_eq!(
            dialect.like_predicate("`a`", "{p0:String}", LikeForm::contains()),
            "`a` LIKE {p0:String}"
        );
        assert_eq!(
            dialect.like_predicate("`a`", "{p0:String}", LikeForm::insensitive(true)),
            "`a` NOT ILIKE {p0:String}"
        );
    }

    #[test]
    fn writes_are_mutations_and_counts_are_not_exact() {
        let dialect = dialect();

        assert!(!SqlDialect::capabilities(&dialect).exact_row_counts);
        assert_eq!(
            dialect.update_statement("t", "a = 1", "id = 2"),
            "ALTER TABLE t UPDATE a = 1 WHERE id = 2"
        );
        assert_eq!(
            dialect.delete_statement("t", "id = 1"),
            "ALTER TABLE t DELETE WHERE id = 1"
        );
        assert!(dialect.insert_default_row("t").is_none());
        assert_eq!(
            dialect.key_probe("t", "id = 1"),
            "SELECT count() FROM (SELECT 1 FROM t WHERE id = 1 LIMIT 2)"
        );
        assert_eq!(dialect.count_all(), "count()");
        assert_eq!(
            dialect.row_value_after(
                &["`a`".to_owned(), "`b`".to_owned()],
                &["{p0:Int32}".to_owned(), "{p1:Int32}".to_owned()],
                KeysetDirection::After
            ),
            "(`a`, `b`) > ({p0:Int32}, {p1:Int32})"
        );
    }

    #[test]
    fn parse_type_classifies_through_the_server_type_parser() {
        let parsed = dialect().parse_type("Nullable(Decimal(18, 4))").expect("a type");

        assert_eq!(
            parsed.kind,
            ColumnKind::Decimal {
                precision: Some(18),
                scale: Some(4)
            }
        );
        assert_eq!(
            dialect().parse_type("UInt8").map(|parsed| parsed.kind),
            Ok(ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W8,
                signed: false
            }))
        );
    }
}
