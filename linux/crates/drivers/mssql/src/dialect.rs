use tablepro_core::column::{
    BoolStorage, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, SqlExpression,
    TemporalZone, TextLength,
};
use tablepro_core::ddl::DdlDialect;
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LikeCase, LikeForm, LiteralError, Placeholder,
    SqlDialect,
};
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

use crate::catalog::SqlServerType;
use crate::ddl::MSSQL_DDL;

/// A string literal in the national character set. Without the `N`, the
/// server reads the text in the database's code page and loses every
/// character outside it.
pub(crate) fn national_literal(text: &str) -> String {
    format!("N'{}'", text.replace('\'', "''"))
}

/// How SQL Server spells SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MssqlDialect {
    major_version: u32,
}

impl MssqlDialect {
    pub fn new(major_version: u32) -> Self {
        Self { major_version }
    }

    pub fn major_version(&self) -> u32 {
        self.major_version
    }
}

impl SqlDialect for MssqlDialect {
    /// SQL Server adds the rows its triggers touch to a statement's
    /// count, so a write proves itself with a probe instead.
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            exact_row_counts: false,
        }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::MsSql
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("[{}]", name.replace(']', "]]"))
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let marker = format!("@P{}", ordinal + 1);
        let param_type = match target {
            BindTarget::Pattern => ParamType::Text,
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a SQL Server column",
                    found: "another engine's row address",
                });
            }
            BindTarget::Column(column) => param_type_for(column)?,
        };
        let sql = match (&param_type, target) {
            (ParamType::ServerText(cast), _) => format!("CAST({marker} AS {cast})"),
            (ParamType::Timestamp, BindTarget::Column(column)) => match legacy_datetime(column) {
                Some(legacy) => format!("CAST({marker} AS {legacy})"),
                None => marker,
            },
            _ => marker,
        };
        Ok(Placeholder::bound(sql, BoundParam::new(value, param_type)?))
    }

    fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            // BIT takes 0 or 1; there is no boolean literal.
            Value::Bool(flag) => Ok(if *flag { "1" } else { "0" }.to_owned()),
            Value::Int(integer) => Ok(integer.to_string()),
            Value::UInt(integer) => Ok(integer.to_string()),
            Value::WideInt(integer) => Ok(integer.to_string()),
            Value::Decimal(decimal) if decimal.is_finite() => Ok(decimal.to_string()),
            // Debug keeps the point or the exponent, so `2.0` stays a
            // float rather than reading back as the integer 2.
            Value::Float32(real) if real.is_finite() => Ok(format!("{:?}", f64::from(*real))),
            Value::Float64(real) if real.is_finite() => Ok(format!("{real:?}")),
            Value::Text(text) => Ok(national_literal(text)),
            Value::Json(json) => Ok(national_literal(json.as_str())),
            Value::Other(other) => Ok(national_literal(&other.text)),
            Value::Bytes(bytes) => Ok(format!("0x{}", tablepro_core::hex::encode_lower(bytes))),
            Value::Uuid(uuid) => Ok(format!("'{uuid}'")),
            // ISO 8601 with the `T` reads the same under every language
            // and DATEFORMAT setting, which the space form does not.
            Value::Date(Temporal::Finite(date)) => Ok(format!("'{}'", date.format("%Y-%m-%d"))),
            Value::Time(time) => Ok(format!("'{}'", time.format(fraction_digits(column)))),
            Value::Timestamp(Temporal::Finite(stamp)) => Ok(format!(
                "'{}{}'",
                stamp.format("%Y-%m-%dT%H:%M:%S"),
                fraction(stamp.and_utc().timestamp_subsec_nanos(), fraction_digits(column))
            )),
            Value::TimestampTz(Temporal::Finite(stamp)) => {
                let local = stamp.to_datetime();
                Ok(format!(
                    "'{}{}{}'",
                    local.format("%Y-%m-%dT%H:%M:%S"),
                    fraction(local.timestamp_subsec_nanos(), fraction_digits(column)),
                    local.format("%:z")
                ))
            }
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            other => Err(LiteralError::Unrepresentable {
                found: other.variant_name(),
            }),
        }
    }

    /// `[` opens a character class in T-SQL patterns, so it is escaped
    /// with the wildcards.
    fn escape_like_text(&self, text: &str) -> String {
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if matches!(character, '!' | '%' | '_' | '[') {
                escaped.push('!');
            }
            escaped.push(character);
        }
        escaped
    }

    /// LOWER() on both sides keeps an insensitive filter insensitive
    /// under a case-sensitive collation.
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

    /// OFFSET … FETCH is part of ORDER BY in T-SQL, so a page with no
    /// sort still needs one; `(SELECT NULL)` orders nothing.
    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        let order = order_by
            .map(str::trim)
            .filter(|order| !order.is_empty())
            .unwrap_or("(SELECT NULL)");
        format!(" ORDER BY {order} OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY")
    }

    /// SQL Server has no row-value comparison, so `(a, b) > (?, ?)` is
    /// written out: `a > ? OR (a = ? AND b > ?)`.
    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        let comparison = direction.comparison();
        let mut branches = Vec::with_capacity(key_sql.len());
        for (last, key) in key_sql.iter().enumerate() {
            let mut terms: Vec<String> = key_sql
                .iter()
                .zip(markers)
                .take(last)
                .map(|(earlier, marker)| format!("{earlier} = {marker}"))
                .collect();
            let marker = markers.get(last).map(String::as_str).unwrap_or_default();
            terms.push(format!("{key} {comparison} {marker}"));
            branches.push(match terms.len() {
                1 => terms.concat(),
                _ => format!("({})", terms.join(" AND ")),
            });
        }
        branches.join(" OR ")
    }

    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::MsSql, text, MAX_TYPE_LEN)?;
        let (mut column_type, _) = SqlServerType::parse(&parsed.text).column_type();
        // A draft has no catalogue yet; its own spelling is the one to
        // splice into DDL.
        column_type.name = parsed.text;
        Ok(column_type)
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::MsSql, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(&MSSQL_DDL)
    }

    /// A type the driver cannot decode is read as the server's text, and
    /// money as a decimal of its own scale: tiberius reads MONEY as a
    /// float, which would round it.
    fn projection(&self, column: &ColumnInfo) -> String {
        let name = self.quote_identifier(&column.name);
        match column.column_type.read_form {
            ReadForm::ServerText => format!("CAST({name} AS nvarchar(max)) AS {name}"),
            ReadForm::ServerNumeric => format!("CAST({name} AS {}) AS {name}", money_decimal(&column.column_type)),
            ReadForm::Native => name,
        }
    }

    /// xml takes neither LIKE nor `=`.
    fn text_operand(&self, column: &ColumnInfo) -> Option<String> {
        matches!(column.column_type.kind, ColumnKind::Xml)
            .then(|| format!("CAST({} AS nvarchar(max))", self.quote_identifier(&column.name)))
    }

    fn equality_as_text(&self, column: &ColumnInfo) -> bool {
        matches!(column.column_type.kind, ColumnKind::Xml)
    }

    /// COUNT(*) is an int on SQL Server and overflows past two billion
    /// rows.
    fn count_all(&self) -> &'static str {
        "COUNT_BIG(*)"
    }

    /// The lock hints hold the probed key until commit, so the row cannot
    /// change between the probe and the write.
    fn key_probe(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!(
            "SELECT COUNT_BIG(*) FROM (SELECT TOP (2) 1 AS one FROM {table_sql} WITH (UPDLOCK, HOLDLOCK) WHERE {predicate_sql}) AS probe"
        )
    }
}

/// The decimal a money column is read as: MONEY's own range and scale,
/// or SMALLMONEY's.
fn money_decimal(column: &ColumnType) -> &'static str {
    let declared = column
        .catalog
        .as_ref()
        .map_or(column.name.as_str(), |catalog| catalog.declaration.as_sql());
    match declared.eq_ignore_ascii_case("smallmoney") {
        true => "decimal(10,4)",
        false => "decimal(19,4)",
    }
}

fn fraction_digits(column: &ColumnType) -> Option<u8> {
    column.kind.fractional_digits()
}

/// The fraction of a second as SQL Server accepts it for the column:
/// datetime takes three digits at most, datetime2 seven.
fn fraction(nanos: u32, digits: Option<u8>) -> String {
    let digits = usize::from(digits.unwrap_or(7).min(7));
    let text = format!("{:09}", nanos.min(999_999_999));
    let kept = text.get(..digits).unwrap_or_default().trim_end_matches('0');
    match kept.is_empty() {
        true => String::new(),
        false => format!(".{kept}"),
    }
}

/// tiberius sends every timestamp as datetime2(7), and SQL Server widens
/// a datetime column to compare with it: a stored .003 becomes .0033333,
/// so the value the grid shows matches no row. Cast back to the column's
/// own type and both sides round the same way.
fn legacy_datetime(column: &ColumnInfo) -> Option<&'static str> {
    let declared = column.column_type.catalog.as_ref()?.cast_target.as_sql();
    ["datetime", "smalldatetime"]
        .into_iter()
        .find(|legacy| declared.eq_ignore_ascii_case(legacy))
}

/// The parameter type a column takes.
fn param_type_for(column: &ColumnInfo) -> Result<ParamType, BindError> {
    let column_type = &column.column_type;
    Ok(match &column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => ParamType::Bool,
        ColumnKind::Bool(BoolStorage::Integer) => ParamType::Int64,
        ColumnKind::Integer(kind) => integer_param_type(*kind),
        ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => ParamType::Decimal,
        ColumnKind::Float(FloatWidth::F32) => ParamType::Float32,
        ColumnKind::Float(FloatWidth::F64) => ParamType::Float64,
        ColumnKind::Text {
            length: TextLength::Fixed(_),
        } => ParamType::FixedText,
        ColumnKind::Text { .. } | ColumnKind::Enum { .. } | ColumnKind::Xml | ColumnKind::Json { .. } => {
            ParamType::Text
        }
        ColumnKind::Bytes { .. } => ParamType::Bytes,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time { .. } => ParamType::Time,
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => ParamType::TimestampTz,
        ColumnKind::Timestamp { .. } => ParamType::Timestamp,
        // A type only the server names binds as text and is cast on the
        // way in, to the type the catalogue gave.
        ColumnKind::Spatial
        | ColumnKind::Variant
        | ColumnKind::Other
        | ColumnKind::Composite
        | ColumnKind::Network(_)
        | ColumnKind::BitString { .. }
        | ColumnKind::Array { .. }
        | ColumnKind::Interval => match &column_type.catalog {
            Some(catalog) => ParamType::ServerText(catalog.cast_target.clone()),
            None => {
                return Err(BindError::MissingCatalogType {
                    column: column.name.clone(),
                });
            }
        },
    })
}

/// tinyint is unsigned 0..255, which a smallint parameter holds.
fn integer_param_type(kind: IntegerKind) -> ParamType {
    match kind.width {
        IntegerWidth::W8 | IntegerWidth::W16 => ParamType::Int16,
        IntegerWidth::W24 | IntegerWidth::W32 => ParamType::Int32,
        IntegerWidth::W64 if kind.signed => ParamType::Int64,
        IntegerWidth::W64 | IntegerWidth::W128 | IntegerWidth::W256 => ParamType::Decimal,
    }
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, NaiveDate};
    use tablepro_core::column::{ColumnDefault, SqlTypeExpr};
    use tablepro_core::value::OffsetTimestamp;

    use super::*;

    fn dialect() -> MssqlDialect {
        MssqlDialect::new(16)
    }

    fn column(declared: &str) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: SqlServerType::parse(declared).column_type().0,
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn bound(declared: &str, value: Value) -> Placeholder {
        dialect()
            .placeholder(0, value, BindTarget::Column(&column(declared)))
            .unwrap()
    }

    #[test]
    fn null_varbinary_binds_as_bytes() {
        let placeholder = bound("varbinary(max)", Value::Null);

        assert_eq!(placeholder.sql, "@P1");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::Bytes)
        );
    }

    #[test]
    fn markers_count_from_the_params_already_bound() {
        let placeholder = dialect()
            .placeholder(2, Value::Int(7), BindTarget::Column(&column("int")))
            .unwrap();

        assert_eq!(placeholder.sql, "@P3");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::Int32)
        );
    }

    #[test]
    fn a_legacy_datetime_parameter_is_cast_to_the_column_type() {
        let stamp = NaiveDate::from_ymd_opt(2024, 6, 15)
            .and_then(|date| date.and_hms_milli_opt(10, 0, 0, 3))
            .unwrap();
        let timestamp = || Value::Timestamp(tablepro_core::value::Temporal::Finite(stamp));

        assert_eq!(bound("datetime", timestamp()).sql, "CAST(@P1 AS datetime)");
        assert_eq!(bound("smalldatetime", timestamp()).sql, "CAST(@P1 AS smalldatetime)");
        assert_eq!(bound("datetime2(3)", timestamp()).sql, "@P1");
    }

    #[test]
    fn a_type_only_the_server_names_is_cast_from_text() {
        let placeholder = bound("hierarchyid", Value::Text("/1/2/".to_owned()));

        assert_eq!(placeholder.sql, "CAST(@P1 AS hierarchyid)");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::ServerText(SqlTypeExpr::from_catalog_text("hierarchyid")))
        );
        assert!(
            dialect()
                .placeholder(0, Value::Int(1), BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid))
                .is_err()
        );
    }

    #[test]
    fn like_escape_covers_the_bracket() {
        assert_eq!(dialect().escape_like_text("50%_[a]!"), "50!%!_![a]!!");
        assert_eq!(
            dialect().like_predicate("[c]", "@P1", LikeForm::contains()),
            "[c] LIKE @P1 ESCAPE '!'"
        );
        assert_eq!(
            dialect().like_predicate("[c]", "@P1", LikeForm::insensitive(true)),
            "LOWER([c]) NOT LIKE LOWER(@P1)"
        );
    }

    #[test]
    fn row_value_after_is_written_out() {
        let keys = ["[a]".to_owned(), "[b]".to_owned()];
        let markers = ["@P1".to_owned(), "@P2".to_owned()];

        assert_eq!(
            dialect().row_value_after(&keys, &markers, KeysetDirection::After),
            "[a] > @P1 OR ([a] = @P1 AND [b] > @P2)"
        );
        assert_eq!(
            dialect().row_value_after(&keys[..1], &markers[..1], KeysetDirection::Before),
            "[a] < @P1"
        );
    }

    #[test]
    fn a_page_without_a_sort_still_orders_for_offset() {
        assert_eq!(
            dialect().row_window(None, 50, 100),
            " ORDER BY (SELECT NULL) OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY"
        );
        assert_eq!(
            dialect().row_window(Some("[id]"), 10, 0),
            " ORDER BY [id] OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY"
        );
    }

    #[test]
    fn literals_use_national_text_hex_bytes_and_iso_dates() {
        let text = column("nvarchar(max)").column_type;
        let stamp = column("datetime").column_type;
        let offset = column("datetimeoffset(7)").column_type;
        let dialect = dialect();

        assert_eq!(
            dialect.literal(&Value::Text("it's".to_owned()), &text).unwrap(),
            "N'it''s'"
        );
        assert_eq!(
            dialect.literal(&Value::Bytes(vec![0xab, 0x01]), &text).unwrap(),
            "0xab01"
        );
        assert_eq!(dialect.literal(&Value::Bool(true), &text).unwrap(), "1");
        let at = NaiveDate::from_ymd_opt(2024, 1, 2)
            .and_then(|date| date.and_hms_nano_opt(3, 4, 5, 123_456_700))
            .unwrap();
        assert_eq!(
            dialect
                .literal(&Value::Timestamp(Temporal::Finite(at)), &stamp)
                .unwrap(),
            "'2024-01-02T03:04:05.123'"
        );
        let local = DateTime::parse_from_rfc3339("2025-04-01T00:00:00.5+05:30").unwrap();
        assert_eq!(
            dialect
                .literal(
                    &Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(local))),
                    &offset
                )
                .unwrap(),
            "'2025-04-01T00:00:00.5+05:30'"
        );
        assert!(dialect.literal(&Value::Float64(f64::NAN), &text).is_err());
    }

    #[test]
    fn money_and_text_only_types_are_projected_through_a_cast() {
        let dialect = dialect();
        let mut money = column("money");
        money.name = "price".to_owned();
        let small = column("smallmoney");
        let place = column("geography");

        assert_eq!(dialect.projection(&money), "CAST([price] AS decimal(19,4)) AS [price]");
        assert_eq!(dialect.projection(&small), "CAST([c] AS decimal(10,4)) AS [c]");
        assert_eq!(dialect.projection(&place), "CAST([c] AS nvarchar(max)) AS [c]");
        assert_eq!(dialect.projection(&column("int")), "[c]");
        assert_eq!(dialect.count_all(), "COUNT_BIG(*)");
    }

    #[test]
    fn the_key_probe_holds_its_locks() {
        assert_eq!(
            dialect().key_probe("[dbo].[t]", "[id] = @P1"),
            "SELECT COUNT_BIG(*) FROM (SELECT TOP (2) 1 AS one FROM [dbo].[t] WITH (UPDLOCK, HOLDLOCK) WHERE [id] = @P1) AS probe"
        );
    }

    #[test]
    fn quote_ident_brackets_and_escapes() {
        let dialect = dialect();

        assert_eq!(dialect.quote_identifier("users"), "[users]");
        assert_eq!(dialect.quote_identifier("weird]name"), "[weird]]name]");
        assert_eq!(
            dialect.qualify(&tablepro_core::meta::TableRef::new(Some("dbo".to_owned()), "users")),
            "[dbo].[users]"
        );
    }

    #[test]
    fn a_typed_type_parses_into_its_kind() {
        let parsed = dialect().parse_type("decimal(10, 2)").unwrap();

        assert_eq!(
            parsed.kind,
            ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2)
            }
        );
        assert_eq!(parsed.name, "decimal(10, 2)");
        assert!(dialect().parse_type("int; DROP TABLE t").is_err());
    }

    #[test]
    fn literal_round_trip_through_the_sql_server_parser() {
        let dialect = dialect();
        let text = column("nvarchar(max)").column_type;
        for value in [
            Value::Text("O'Brien [x] 50%".to_owned()),
            Value::Int(-42),
            Value::Decimal("123.4500".parse().unwrap()),
            Value::Bytes(vec![0, 255]),
        ] {
            let literal = dialect.literal(&value, &text).unwrap();
            assert!(dialect.parse_expression(&literal).is_ok(), "{literal}");
        }
    }
}
