use crate::query::{ColumnInfo, Value};
use crate::sql_dialect::{BuildSqlError, quote_ident};
use chrono::{Datelike, Timelike};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum LiteralError {
    #[error("the value could not be decoded")]
    Undecodable,
    #[error("non-finite numbers cannot be exported as SQL literals")]
    NonFinite,
    #[error("this engine does not support this SQL literal")]
    Unsupported,
}

/// Select the coarsest `DateTime64` scale that represents a timestamp exactly
/// and fits ClickHouse's Int64 tick storage and calendar bounds.
pub fn clickhouse_datetime64_precision(stamp: chrono::NaiveDateTime) -> Option<u32> {
    (0..=9).find(|precision| clickhouse_datetime64_fits_precision(stamp, *precision))
}

/// Render a timestamp as a precision-preserving ClickHouse DateTime64 literal.
/// An optional timezone is included in the native expression.
pub fn clickhouse_datetime64_literal(stamp: chrono::NaiveDateTime, timezone: Option<&str>) -> Option<String> {
    let precision = clickhouse_datetime64_precision(stamp)?;
    let value = if precision == 0 {
        stamp.format("%Y-%m-%d %H:%M:%S").to_string()
    } else {
        let divisor = 10_u32.pow(9 - precision);
        let fractional = stamp.nanosecond() / divisor;
        format!(
            "{}.{fractional:0width$}",
            stamp.format("%Y-%m-%d %H:%M:%S"),
            width = precision as usize
        )
    };
    match timezone {
        Some(zone) => Some(format!("toDateTime64('{value}', {precision}, '{zone}')")),
        None => Some(format!("toDateTime64('{value}', {precision})")),
    }
}

fn clickhouse_datetime64_fits_precision(stamp: chrono::NaiveDateTime, precision: u32) -> bool {
    let Some(minimum) = chrono::NaiveDate::from_ymd_opt(1900, 1, 1).and_then(|date| date.and_hms_opt(0, 0, 0)) else {
        return false;
    };
    let Some(maximum) =
        chrono::NaiveDate::from_ymd_opt(2299, 12, 31).and_then(|date| date.and_hms_nano_opt(23, 59, 59, 999_999_999))
    else {
        return false;
    };
    if !(minimum..=maximum).contains(&stamp) || precision > 9 {
        return false;
    }
    let fraction_divisor = 10_u32.pow(9 - precision);
    if !stamp.nanosecond().is_multiple_of(fraction_divisor) {
        return false;
    }
    let scale = 10_i128.pow(precision);
    let ticks = i128::from(stamp.and_utc().timestamp()) * scale + i128::from(stamp.nanosecond() / fraction_divisor);
    (i128::from(i64::MIN)..=i128::from(i64::MAX)).contains(&ticks)
}

/// Render `value` as a SQL literal for `driver_id`.
///
/// Escaping is dialect-specific and getting it wrong is not cosmetic.
/// MySQL and ClickHouse treat a backslash as an escape character inside
/// a string literal, so a value ending in one would consume the closing
/// quote and let the rest of the value parse as SQL. PostgreSQL's regular
/// string behavior depends on `standard_conforming_strings`; backslash-bearing
/// literals use explicit `E''` syntax so their value is independent of session
/// settings. SQLite and SQL Server treat backslash as an ordinary character.
///
/// Row values come from the database, which the project treats as
/// untrusted input.
pub fn render_sql_literal(driver_id: &str, value: &Value) -> Result<String, LiteralError> {
    if !crate::export::supports_sql_literals(driver_id) {
        return Err(LiteralError::Unsupported);
    }
    if driver_id == "postgres"
        && let Some(text) = postgres_extended_date(value)
    {
        return Ok(string_literal(driver_id, &text));
    }
    Ok(match value {
        Value::Null => "NULL".into(),
        Value::Bool(value) if driver_id == "mssql" => u8::from(*value).to_string(),
        Value::Bool(value) => value.to_string(),
        Value::Int(value) => value.to_string(),
        Value::Float(value) if !value.is_finite() => return Err(LiteralError::NonFinite),
        Value::Float(value) if driver_id == "sqlite" && *value == 0.0 && value.is_sign_negative() => {
            return Err(LiteralError::Unsupported);
        }
        Value::Float(value) => format!("{value:e}"),
        Value::Decimal(value) if driver_id == "duckdb" => {
            let precision = value
                .mantissa()
                .unsigned_abs()
                .to_string()
                .len()
                .max(value.scale() as usize)
                .max(1);
            format!("CAST({value} AS DECIMAL({precision}, {}))", value.scale())
        }
        Value::Decimal(value) if driver_id == "clickhouse" => format!("toDecimal128('{value}', {})", value.scale()),
        Value::Decimal(value) => value.to_string(),
        Value::Text(text) => string_literal(driver_id, text),
        Value::Bytes(bytes) => binary_literal(driver_id, bytes)?,
        Value::Date(date) => string_literal(driver_id, &date.format("%Y-%m-%d").to_string()),
        Value::Time(time) => string_literal(driver_id, &time.to_string()),
        Value::DateTime(stamp) if driver_id == "clickhouse" => {
            clickhouse_datetime64_literal(*stamp, None).ok_or(LiteralError::Unsupported)?
        }
        Value::DateTime(stamp) if driver_id == "mssql" => {
            format!("CAST({} AS datetime2)", string_literal(driver_id, &stamp.to_string()))
        }
        Value::TimestampTz(stamp) if driver_id == "clickhouse" => {
            clickhouse_datetime64_literal(stamp.naive_utc(), Some("UTC")).ok_or(LiteralError::Unsupported)?
        }
        Value::DateTime(stamp) => string_literal(driver_id, &stamp.to_string()),
        Value::TimestampTz(stamp) => string_literal(driver_id, &stamp.to_rfc3339()),
        Value::Uuid(id) => string_literal(driver_id, &id.to_string()),
        Value::Json(_) if driver_id == "clickhouse" => return Err(LiteralError::Unsupported),
        Value::Json(json) => string_literal(driver_id, &json.to_string()),
        Value::Undecodable(_) => return Err(LiteralError::Undecodable),
    })
}

fn postgres_extended_date(value: &Value) -> Option<String> {
    let date = match value {
        Value::Date(date) => *date,
        Value::DateTime(stamp) => stamp.date(),
        Value::TimestampTz(stamp) => stamp.date_naive(),
        _ => return None,
    };
    if (1..=9999).contains(&date.year()) {
        return None;
    }
    postgres_temporal_text(value)
}

pub fn postgres_temporal_text(value: &Value) -> Option<String> {
    let (date, time, zone) = match value {
        Value::Date(date) => (*date, None, ""),
        Value::DateTime(stamp) => (stamp.date(), Some(stamp.time()), ""),
        Value::TimestampTz(stamp) => (stamp.date_naive(), Some(stamp.time()), "+00:00"),
        _ => return None,
    };
    let (common_era, year) = date.year_ce();
    let mut text = format!("{year:04}-{:02}-{:02}", date.month(), date.day());
    if let Some(time) = time {
        text.push_str(&format!(" {time}{zone}"));
    }
    if !common_era {
        text.push_str(" BC");
    }
    Some(text)
}

fn string_literal(driver_id: &str, text: &str) -> String {
    // MySQL reads a backslash as an escape unless sql_mode has NO_BACKSLASH_ESCAPES, and a
    // generated INSERT cannot know the mode of the server it will run on. A charset-tagged
    // hex literal means the same text in both modes, where any quoted form breaks one of them.
    if driver_id == "mysql" && text.contains(['\\', '\0']) {
        return format!("_utf8mb4 X'{}'", crate::export::hex_encode(text.as_bytes()));
    }
    if driver_id == "postgres" && text.contains('\\') {
        let escaped = text.replace('\\', "\\\\").replace('\'', "''");
        return format!("E'{escaped}'");
    }
    quote_literal(driver_id, text)
}

fn binary_literal(driver_id: &str, bytes: &[u8]) -> Result<String, LiteralError> {
    let hex = crate::export::hex_encode(bytes);
    match driver_id {
        "postgres" => Ok(format!("decode('{hex}', 'hex')")),
        "mysql" | "sqlite" => Ok(format!("X'{hex}'")),
        "mssql" => Ok(format!("0x{hex}")),
        "clickhouse" => Ok(format!("unhex('{hex}')")),
        "duckdb" => Ok(format!("from_hex('{hex}')")),
        _ => Err(LiteralError::Unsupported),
    }
}

pub(crate) fn quote_literal(driver_id: &str, text: &str) -> String {
    let escaped = match driver_id {
        "mysql" | "clickhouse" => text.replace('\\', "\\\\").replace('\'', "''"),
        _ => text.replace('\'', "''"),
    };
    let prefix = if driver_id == "mssql" { "N" } else { "" };
    format!("{prefix}'{escaped}'")
}

/// Render a complete `INSERT` for one result row, for the user to paste
/// and run.
///
/// Generated columns are left out because the database computes them.
/// PostgreSQL and SQL Server identities are also left out so the target
/// database assigns a fresh key; MySQL's explicit auto-increment copy stays.
pub fn build_insert_literal(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    row: &[Value],
) -> Result<String, BuildSqlError> {
    if columns.len() != row.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: row.len(),
        });
    }
    let mut names: Vec<String> = Vec::with_capacity(columns.len());
    let mut values: Vec<String> = Vec::with_capacity(columns.len());
    for (column, value) in columns.iter().zip(row) {
        if column.is_generated || (column.is_auto_increment && matches!(driver_id, "postgres" | "mssql")) {
            continue;
        }
        names.push(quote_ident(driver_id, &column.name));
        let literal = if driver_id == "mysql" && matches!(value, Value::Text(text) if text.is_empty()) {
            // MariaDB's EMPTY_STRING_IS_NULL mode turns an empty SQL string
            // literal into NULL. SPACE(0) stays an empty value for text,
            // ENUM, and SET destinations during SQL-file replay.
            "SPACE(0)".to_owned()
        } else {
            render_sql_literal(driver_id, value).map_err(|_| BuildSqlError::UnrepresentableValue {
                column: column.name.clone(),
            })?
        };
        values.push(literal);
    }
    let qualified = match schema {
        Some(schema) => format!("{}.{}", quote_ident(driver_id, schema), quote_ident(driver_id, table)),
        None => quote_ident(driver_id, table),
    };
    if names.is_empty() {
        return if matches!(driver_id, "postgres" | "mssql") {
            Ok(format!("INSERT INTO {qualified} DEFAULT VALUES;"))
        } else {
            Err(BuildSqlError::NothingToUpdate)
        };
    }
    Ok(format!(
        "INSERT INTO {} ({}) VALUES ({});",
        qualified,
        names.join(", "),
        values.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn postgres_backslash_literals_do_not_depend_on_session_mode() {
        assert_eq!(
            render_sql_literal("postgres", &Value::Text(r"back\nslash\end'quote".into())).unwrap(),
            r#"E'back\\nslash\\end''quote'"#
        );
    }

    #[test]
    fn value_contract_postgres_dates_preserve_eras_and_extended_years() {
        for (year, expected) in [
            (0, "0001-02-03 BC"),
            (-1, "0002-02-03 BC"),
            (-4712, "4713-02-03 BC"),
            (10000, "10000-02-03"),
            (262000, "262000-02-03"),
        ] {
            let date = chrono::NaiveDate::from_ymd_opt(year, 2, 3).unwrap();
            assert_eq!(
                render_sql_literal("postgres", &Value::Date(date)).unwrap(),
                format!("'{expected}'")
            );
            let (body, era) = expected
                .strip_suffix(" BC")
                .map_or((expected, ""), |body| (body, " BC"));
            let stamp = date.and_hms_micro_opt(12, 34, 56, 123456).unwrap();
            assert_eq!(
                render_sql_literal("postgres", &Value::DateTime(stamp)).unwrap(),
                format!("'{body} 12:34:56.123456{era}'")
            );
            assert_eq!(
                render_sql_literal("postgres", &Value::TimestampTz(stamp.and_utc())).unwrap(),
                format!("'{body} 12:34:56.123456+00:00{era}'")
            );
            assert_eq!(
                render_sql_literal("sqlite", &Value::Date(date)).unwrap(),
                format!("'{}'", date.format("%Y-%m-%d"))
            );
        }
        for year in [1, 2026, 9999] {
            let date = chrono::NaiveDate::from_ymd_opt(year, 2, 3).unwrap();
            assert_eq!(postgres_extended_date(&Value::Date(date)), None);
            assert_eq!(
                render_sql_literal("postgres", &Value::Date(date)).unwrap(),
                format!("'{year:04}-02-03'")
            );
        }
        assert_eq!(postgres_extended_date(&Value::Text("0000-02-03".into())), None);
    }

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    fn generated(name: &str) -> ColumnInfo {
        ColumnInfo {
            is_generated: true,
            comment: None,
            ..column(name)
        }
    }

    #[test]
    fn value_contract_numeric_literals_avoid_implicit_decimal_and_float_conversions() {
        let decimal = Value::Decimal("99999999999999999999.99999999".parse().unwrap());
        assert_eq!(
            render_sql_literal("clickhouse", &decimal).unwrap(),
            "toDecimal128('99999999999999999999.99999999', 8)"
        );
        assert_eq!(
            render_sql_literal("duckdb", &decimal).unwrap(),
            "CAST(99999999999999999999.99999999 AS DECIMAL(28, 8))"
        );
        for driver in ["postgres", "mysql", "sqlite", "mssql", "clickhouse", "duckdb"] {
            assert_eq!(render_sql_literal(driver, &Value::Float(1e-200)).unwrap(), "1e-200");
            assert_eq!(render_sql_literal(driver, &Value::Float(1e200)).unwrap(), "1e200");
        }
    }

    #[test]
    fn dialect_specific_decimal_and_temporal_literals_stay_with_their_engines() {
        let decimal = Value::Decimal("123.4500".parse().unwrap());
        assert_eq!(
            render_sql_literal("clickhouse", &decimal).unwrap(),
            "toDecimal128('123.4500', 4)"
        );
        assert_eq!(render_sql_literal("postgres", &decimal).unwrap(), "123.4500");

        let stamp = chrono::NaiveDate::from_ymd_opt(2026, 10, 10)
            .unwrap()
            .and_hms_micro_opt(12, 34, 56, 123_400)
            .unwrap();
        assert_eq!(
            render_sql_literal("clickhouse", &Value::DateTime(stamp)).unwrap(),
            "toDateTime64('2026-10-10 12:34:56.1234', 4)"
        );
        assert_eq!(
            render_sql_literal("clickhouse", &Value::TimestampTz(stamp.and_utc())).unwrap(),
            "toDateTime64('2026-10-10 12:34:56.1234', 4, 'UTC')"
        );
        assert_eq!(
            render_sql_literal("postgres", &Value::DateTime(stamp)).unwrap(),
            "'2026-10-10 12:34:56.123400'"
        );
        assert_eq!(
            render_sql_literal("postgres", &Value::TimestampTz(stamp.and_utc())).unwrap(),
            "'2026-10-10T12:34:56.123400+00:00'"
        );
        assert_eq!(
            render_sql_literal("mssql", &Value::DateTime(stamp)).unwrap(),
            "CAST(N'2026-10-10 12:34:56.123400' AS datetime2)"
        );
    }

    #[test]
    fn sqlite_refuses_negative_zero_without_refusing_positive_zero() {
        assert_eq!(
            render_sql_literal("sqlite", &Value::Float(-0.0)),
            Err(LiteralError::Unsupported)
        );
        assert_eq!(render_sql_literal("sqlite", &Value::Float(0.0)).unwrap(), "0e0");
        assert_eq!(render_sql_literal("postgres", &Value::Float(-0.0)).unwrap(), "-0e0");
    }

    #[test]
    fn sql_server_literals_preserve_unicode_and_use_numeric_booleans() {
        assert_eq!(
            render_sql_literal("mssql", &Value::Text("漢字 😀 O'Brien".into())).unwrap(),
            "N'漢字 😀 O''Brien'"
        );
        assert_eq!(render_sql_literal("mssql", &Value::Bool(true)).unwrap(), "1");
        assert_eq!(render_sql_literal("mssql", &Value::Bool(false)).unwrap(), "0");
    }

    #[test]
    fn clickhouse_datetime64_exports_refuse_values_outside_its_nanosecond_range() {
        let below = chrono::NaiveDate::from_ymd_opt(1899, 12, 31)
            .unwrap()
            .and_hms_nano_opt(23, 59, 59, 999_999_999)
            .unwrap();
        let above = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
            .unwrap()
            .and_hms_nano_opt(23, 47, 16, 854_775_808)
            .unwrap();
        for value in [Value::DateTime(below), Value::TimestampTz(above.and_utc())] {
            assert_eq!(render_sql_literal("clickhouse", &value), Err(LiteralError::Unsupported));
        }
    }

    #[test]
    fn clickhouse_datetime64_literal_uses_the_coarsest_exact_native_precision() {
        let wide = chrono::NaiveDate::from_ymd_opt(2299, 12, 31)
            .unwrap()
            .and_hms_opt(23, 59, 59)
            .unwrap();
        let fractional = chrono::NaiveDate::from_ymd_opt(2026, 9, 30)
            .unwrap()
            .and_hms_nano_opt(12, 34, 56, 123_456_000)
            .unwrap();
        let nanos_edge = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
            .unwrap()
            .and_hms_nano_opt(23, 47, 16, 854_775_807)
            .unwrap();
        let ten_nanos_edge = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
            .unwrap()
            .and_hms_nano_opt(23, 47, 16, 854_775_790)
            .unwrap();
        let past_nanos_edge = chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
            .unwrap()
            .and_hms_nano_opt(23, 47, 16, 854_775_808)
            .unwrap();
        assert_eq!(clickhouse_datetime64_precision(wide), Some(0));
        assert!(!clickhouse_datetime64_fits_precision(wide, 10));
        assert_eq!(
            clickhouse_datetime64_literal(wide, None).as_deref(),
            Some("toDateTime64('2299-12-31 23:59:59', 0)")
        );
        assert_eq!(clickhouse_datetime64_precision(fractional), Some(6));
        assert_eq!(clickhouse_datetime64_precision(nanos_edge), Some(9));
        assert_eq!(clickhouse_datetime64_precision(ten_nanos_edge), Some(8));
        assert_eq!(clickhouse_datetime64_precision(past_nanos_edge), None);
        assert_eq!(
            clickhouse_datetime64_literal(fractional, Some("UTC")).as_deref(),
            Some("toDateTime64('2026-09-30 12:34:56.123456', 6, 'UTC')")
        );
    }

    #[test]
    fn clickhouse_nested_json_export_requires_native_type_metadata() {
        assert_eq!(
            render_sql_literal(
                "clickhouse",
                &Value::Json(serde_json::json!(["18446744073709551616", null]))
            ),
            Err(LiteralError::Unsupported)
        );
        assert_eq!(
            render_sql_literal("postgres", &Value::Json(serde_json::json!({"a": 1}))).unwrap(),
            "'{\"a\":1}'"
        );
    }

    #[test]
    fn insert_export_refuses_values_it_cannot_represent() {
        for value in [Value::Undecodable("NUMERIC".into()), Value::Float(f64::NAN)] {
            let error = build_insert_literal("postgres", None, "items", &[column("value")], &[value])
                .expect_err("export must not turn a value into SQL NULL");
            assert!(matches!(error, BuildSqlError::UnrepresentableValue { column } if column == "value"));
        }
    }

    #[test]
    fn unrepresentable_values_return_errors_without_sql() {
        for driver in ["postgres", "mysql", "sqlite", "mssql", "clickhouse", "duckdb"] {
            assert_eq!(
                render_sql_literal(driver, &Value::Undecodable("*/; DROP TABLE t; --".into())),
                Err(LiteralError::Undecodable)
            );
            for number in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                assert_eq!(
                    render_sql_literal(driver, &Value::Float(number)),
                    Err(LiteralError::NonFinite)
                );
            }
        }
        assert_eq!(
            render_sql_literal("redis", &Value::Int(1)),
            Err(LiteralError::Unsupported)
        );
    }

    /// The exact shape that escaped a MySQL literal: the trailing
    /// backslash consumed the closing quote, so `OR 1=1` parsed as SQL
    /// rather than as data. Verified against MySQL 8.1, which evaluated
    /// the unescaped form as the expression `'x\'' OR 1=1` and returned 1.
    const BREAKOUT: &str = "x\\' OR 1=1 -- ";

    #[test]
    fn a_backslash_is_escaped_only_where_the_engine_treats_it_as_an_escape() {
        assert_eq!(
            render_sql_literal("mysql", &Value::Text(BREAKOUT.into())).unwrap(),
            "_utf8mb4 X'785c27204f5220313d31202d2d20'"
        );
        assert_eq!(
            render_sql_literal("mysql", &Value::Text("nul\0".into())).unwrap(),
            "_utf8mb4 X'6e756c00'"
        );
        assert_eq!(
            render_sql_literal("mysql", &Value::Text("it's".into())).unwrap(),
            "'it''s'"
        );
        assert_eq!(
            render_sql_literal("clickhouse", &Value::Text(BREAKOUT.into())).unwrap(),
            "'x\\\\'' OR 1=1 -- '"
        );
        assert_eq!(
            render_sql_literal("postgres", &Value::Text(BREAKOUT.into())).unwrap(),
            "E'x\\\\'' OR 1=1 -- '",
            "PostgreSQL must use an explicit escape string"
        );
        assert_eq!(
            render_sql_literal("sqlite", &Value::Text(BREAKOUT.into())).unwrap(),
            "'x\\'' OR 1=1 -- '",
            "SQLite must keep a backslash literal"
        );
    }

    #[test]
    fn a_rendered_literal_decodes_back_to_the_value_and_ends_where_it_should() {
        let awkward = [
            BREAKOUT,
            "ends with a backslash \\",
            "'",
            "''",
            "\\",
            "\\\\",
            "a'b\\c",
            "'; DROP TABLE users; --",
            "\\'; DROP TABLE users; --",
            "plain",
            "",
            "multi\nline",
            "unicode \u{2028} and emoji \u{1f600}",
        ];
        for driver_id in ["postgres", "mysql", "sqlite", "mssql", "clickhouse"] {
            for text in awkward {
                let rendered = render_sql_literal(driver_id, &Value::Text(text.into())).unwrap();
                let (decoded, consumed) = decode_literal(driver_id, &rendered)
                    .unwrap_or_else(|| panic!("{driver_id} produced an unterminated literal for {text:?}: {rendered}"));
                assert_eq!(decoded, text, "{driver_id} changed the value: {rendered}");
                assert_eq!(
                    consumed,
                    rendered.chars().count(),
                    "{driver_id} let {text:?} close its literal early, leaving SQL behind: {rendered}"
                );
            }
        }
    }

    /// Decode a rendered literal the way the engine would, returning the
    /// text and how much of the input the literal consumed. A literal
    /// that ends before the end of the rendered string is a break-out:
    /// whatever follows would be parsed as SQL.
    fn decode_literal(driver_id: &str, rendered: &str) -> Option<(String, usize)> {
        if let Some(digits) = rendered
            .strip_prefix("_utf8mb4 X'")
            .and_then(|rest| rest.strip_suffix('\''))
            && driver_id == "mysql"
        {
            let bytes = (0..digits.len())
                .step_by(2)
                .map(|at| u8::from_str_radix(digits.get(at..at + 2)?, 16).ok())
                .collect::<Option<Vec<u8>>>()?;
            return Some((String::from_utf8(bytes).ok()?, rendered.chars().count()));
        }
        let postgres_escape_string = driver_id == "postgres" && rendered.starts_with("E'");
        let backslash_escapes = matches!(driver_id, "mysql" | "clickhouse") || postgres_escape_string;
        let characters: Vec<char> = rendered.chars().collect();
        let prefix = usize::from(driver_id == "mssql" || postgres_escape_string);
        if characters.get(prefix) != Some(&'\'') {
            return None;
        }
        let mut decoded = String::new();
        let mut index = prefix + 1;
        while index < characters.len() {
            match characters[index] {
                '\\' if backslash_escapes => {
                    decoded.push(*characters.get(index + 1)?);
                    index += 2;
                }
                '\'' if characters.get(index + 1) == Some(&'\'') => {
                    decoded.push('\'');
                    index += 2;
                }
                '\'' => return Some((decoded, index + 1)),
                other => {
                    decoded.push(other);
                    index += 1;
                }
            }
        }
        None
    }

    #[test]
    fn an_insert_leaves_out_a_generated_column_the_engine_would_reject() {
        let columns = vec![column("id"), generated("total"), column("note")];
        let row = vec![Value::Int(1), Value::Int(99), Value::Text("hi".into())];
        let sql = build_insert_literal("postgres", None, "t", &columns, &row).expect("build the insert");
        assert_eq!(sql, "INSERT INTO \"t\" (\"id\", \"note\") VALUES (1, 'hi');");
        assert!(!sql.contains("total"));
        assert!(!sql.contains("99"));
    }

    #[test]
    fn copied_insert_uses_the_engine_identity_default() {
        let mut id = column("id");
        id.is_auto_increment = true;
        id.primary_key = true;
        let columns = vec![id, column("note")];
        let row = vec![Value::Int(7), Value::Text("hi".into())];
        assert_eq!(
            build_insert_literal("mysql", None, "t", &columns, &row).unwrap(),
            "INSERT INTO `t` (`id`, `note`) VALUES (7, 'hi');"
        );
        assert_eq!(
            build_insert_literal("postgres", None, "t", &columns, &row).unwrap(),
            "INSERT INTO \"t\" (\"note\") VALUES ('hi');"
        );
        assert_eq!(
            build_insert_literal("mssql", None, "t", &columns, &row).unwrap(),
            "INSERT INTO [t] ([note]) VALUES (N'hi');"
        );
    }

    #[test]
    fn copied_insert_uses_default_values_when_no_column_can_be_written() {
        let mut id = column("id");
        id.is_auto_increment = true;
        let columns = vec![id, generated("computed")];
        let row = vec![Value::Int(7), Value::Int(14)];
        assert_eq!(
            build_insert_literal("postgres", Some("public"), "t", &columns, &row).unwrap(),
            "INSERT INTO \"public\".\"t\" DEFAULT VALUES;"
        );
        assert_eq!(
            build_insert_literal("mssql", Some("dbo"), "t", &columns, &row).unwrap(),
            "INSERT INTO [dbo].[t] DEFAULT VALUES;"
        );
    }

    #[test]
    fn mysql_insert_literals_preserve_empty_text_under_empty_string_is_null_mode() {
        let columns = vec![column("enum_value"), column("set_value"), column("note")];
        let row = vec![
            Value::Text(String::new()),
            Value::Text(String::new()),
            Value::Text(String::new()),
        ];

        let sql = build_insert_literal("mysql", None, "t", &columns, &row).expect("build the insert");

        assert_eq!(
            sql,
            "INSERT INTO `t` (`enum_value`, `set_value`, `note`) VALUES (SPACE(0), SPACE(0), SPACE(0));"
        );
    }

    #[test]
    fn an_insert_qualifies_with_the_schema_and_quotes_per_dialect() {
        let columns = vec![column("a")];
        let row = vec![Value::Int(1)];
        assert_eq!(
            build_insert_literal("postgres", Some("public"), "t", &columns, &row).expect("postgres"),
            "INSERT INTO \"public\".\"t\" (\"a\") VALUES (1);"
        );
        assert_eq!(
            build_insert_literal("mssql", Some("dbo"), "t", &columns, &row).expect("mssql"),
            "INSERT INTO [dbo].[t] ([a]) VALUES (1);"
        );
    }

    #[test]
    fn a_row_that_does_not_match_the_columns_is_refused_rather_than_rendered() {
        let columns = vec![column("a"), column("b")];
        let row = vec![Value::Int(1)];
        let error = build_insert_literal("postgres", None, "t", &columns, &row)
            .expect_err("a mismatched row must not produce SQL");
        assert!(matches!(error, BuildSqlError::LengthMismatch { expected: 2, got: 1 }));
    }

    #[test]
    fn mysql_still_refuses_a_row_of_only_generated_columns() {
        let columns = vec![generated("a")];
        let row = vec![Value::Int(1)];
        let error = build_insert_literal("mysql", None, "t", &columns, &row).expect_err("nothing to insert");
        assert!(matches!(error, BuildSqlError::NothingToUpdate));
    }

    #[test]
    fn scalar_values_render_without_quotes_and_null_stays_a_keyword() {
        assert_eq!(render_sql_literal("postgres", &Value::Null).unwrap(), "NULL");
        assert_eq!(render_sql_literal("postgres", &Value::Bool(true)).unwrap(), "true");
        assert_eq!(render_sql_literal("postgres", &Value::Int(-3)).unwrap(), "-3");
        assert_eq!(render_sql_literal("postgres", &Value::Float(1.5)).unwrap(), "1.5e0");
    }

    #[test]
    fn a_quote_inside_a_value_is_doubled_for_every_dialect() {
        for driver_id in ["postgres", "mysql", "sqlite", "mssql", "clickhouse"] {
            assert_eq!(
                render_sql_literal(driver_id, &Value::Text("O'Brien".into())).unwrap(),
                if driver_id == "mssql" {
                    "N'O''Brien'"
                } else {
                    "'O''Brien'"
                },
                "{driver_id}"
            );
        }
    }

    #[test]
    fn binary_literals_preserve_empty_and_arbitrary_bytes() {
        for (driver, expected, empty) in [
            ("postgres", "decode('00275cff', 'hex')", "decode('', 'hex')"),
            ("mysql", "X'00275cff'", "X''"),
            ("sqlite", "X'00275cff'", "X''"),
            ("mssql", "0x00275cff", "0x"),
            ("clickhouse", "unhex('00275cff')", "unhex('')"),
            ("duckdb", "from_hex('00275cff')", "from_hex('')"),
        ] {
            assert_eq!(
                render_sql_literal(driver, &Value::Bytes(vec![0, 39, 92, 255])).unwrap(),
                expected
            );
            assert_eq!(render_sql_literal(driver, &Value::Bytes(vec![])).unwrap(), empty);
        }
    }
}
