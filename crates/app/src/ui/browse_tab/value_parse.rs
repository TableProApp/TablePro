use chrono::{Datelike, Timelike};
use tablepro_core::{ColumnInfo, Value};

/// Replace newlines / carriage returns with spaces. Applied at
/// cell-edit commit time for non-JSON columns so a multi-line
/// clipboard paste into a single-line cell never reaches the SQL
/// layer with embedded `\n` — driver behaviour for that case is
/// type-specific (text columns store literally; numeric / date
/// columns parse-fail). Preserve all other text exactly.
pub(super) fn normalize_single_line_input(text: &str) -> String {
    text.chars()
        .map(|c| if matches!(c, '\n' | '\r') { ' ' } else { c })
        .collect()
}

pub(super) fn parse_input_for_column(text: &str, col: Option<&ColumnInfo>) -> Result<Value, String> {
    let Some(col) = col else {
        return Ok(Value::Text(text.to_string()));
    };
    if text.is_empty() {
        if col.nullable || col.default_value.is_some() {
            return Ok(Value::Null);
        }
        return Err(crate::tr!("Field is required"));
    }
    let dt = col.data_type.to_ascii_lowercase();
    let trimmed = text.trim();
    if let Some(width) = mysql_bit_width(&dt) {
        return parse_mysql_bit_value(trimmed, width);
    }
    match classify_type(&dt) {
        TypeKind::Bool => parse_bool_value(trimmed),
        TypeKind::Int => parse_int_value(trimmed),
        TypeKind::Float => parse_float_value(trimmed),
        TypeKind::Decimal => parse_decimal_value(trimmed),
        TypeKind::Uuid => parse_uuid_value(trimmed),
        TypeKind::Json => parse_json_value(trimmed),
        TypeKind::TimestampTz => parse_timestamptz_value(trimmed),
        TypeKind::DateTime => parse_datetime_value(trimmed),
        TypeKind::Date => parse_date_value(trimmed),
        TypeKind::Time => parse_time_value(trimmed),
        TypeKind::Text => Ok(Value::Text(text.to_string())),
    }
}

fn parse_mysql_enum_set_input(text: &str, col: Option<&ColumnInfo>) -> Option<Result<Value, String>> {
    let column = col?;
    let data_type = column.data_type.trim();
    let lower = data_type.to_ascii_lowercase();
    let is_enum = lower.starts_with("enum");
    let is_set = lower.starts_with("set");
    if !is_enum && !is_set {
        return None;
    }
    let Some(labels) = parse_mysql_enum_set_labels(data_type) else {
        return Some(Err(crate::tr!("Could not safely read ENUM or SET members")));
    };
    let valid = if is_enum {
        labels.iter().any(|label| label == text)
    } else if text.is_empty() {
        true
    } else {
        text.split(',').all(|member| labels.iter().any(|label| label == member))
    };
    if valid {
        Some(Ok(Value::Text(text.to_owned())))
    } else {
        Some(Err(crate::tr!("Value is not a declared ENUM or SET member")))
    }
}

fn parse_mysql_enum_set_labels(data_type: &str) -> Option<Vec<String>> {
    let open = data_type.find('(')?;
    let kind = data_type[..open].trim();
    if !kind.eq_ignore_ascii_case("enum") && !kind.eq_ignore_ascii_case("set") {
        return None;
    }
    let mut chars = data_type[open + 1..].strip_suffix(')')?.chars().peekable();
    let mut labels = Vec::new();
    loop {
        while chars.peek().is_some_and(|ch| ch.is_whitespace()) {
            chars.next();
        }
        if chars.next()? != '\'' {
            return None;
        }
        let mut label = String::new();
        loop {
            match chars.next()? {
                '\\' => {
                    let escaped = chars.next()?;
                    label.push(match escaped {
                        '0' => '\0',
                        'b' => '\u{0008}',
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'Z' => '\u{001a}',
                        other => other,
                    });
                }
                '\'' if chars.peek() == Some(&'\'') => {
                    chars.next();
                    label.push('\'');
                }
                '\'' => break,
                ch => label.push(ch),
            }
        }
        labels.push(label);
        while chars.peek().is_some_and(|ch| ch.is_whitespace()) {
            chars.next();
        }
        match chars.next() {
            None => return Some(labels),
            Some(',') => {}
            Some(_) => return None,
        }
    }
}

pub(super) fn parse_input_for_driver(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Result<Value, String> {
    // Keep blank input as SQL NULL, while `''` explicitly selects an empty ENUM/SET value.
    if driver_id == "mysql"
        && text == "''"
        && let Some(result) = parse_mysql_enum_set_input("", col)
    {
        return result;
    }
    if text.is_empty() {
        return parse_input_for_column(text, col);
    }
    if driver_id == "mysql"
        && let Some(result) = parse_mysql_enum_set_input(text, col)
    {
        return result;
    }
    let trimmed = text.trim();
    if driver_id == "mysql"
        && let Some(result) = parse_mysql_integer_input(trimmed, col)
    {
        return result;
    }
    if let Some(result) = parse_special_driver_input(trimmed, col, driver_id) {
        return result;
    }
    if driver_id == "sqlite"
        && col.is_some_and(|column| {
            classify_type(&column.data_type.to_ascii_lowercase()) == TypeKind::Text
                && tablepro_core::sqlite_declared_type_has_numeric_affinity(&column.data_type)
        })
    {
        if let Some(value) = tablepro_core::sqlite_affinity_decimal(text) {
            return Ok(Value::Decimal(value));
        }
        return if tablepro_core::is_numeric_input(text) {
            Err(crate::tr!("Invalid number"))
        } else {
            Ok(Value::Text(text.to_owned()))
        };
    }
    match parse_input_for_column(text, col) {
        Err(error) => match sqlite_numeric_affinity_fallback(text, col, driver_id) {
            Some(value) => Ok(value),
            None => Err(error),
        },
        result => result,
    }
}

fn sqlite_numeric_affinity_fallback(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Value> {
    if driver_id != "sqlite"
        || !col.is_some_and(|column| {
            matches!(
                classify_type(&column.data_type.to_ascii_lowercase()),
                TypeKind::Int | TypeKind::Float | TypeKind::Decimal
            )
        })
    {
        return None;
    }
    if let Some(decimal) = tablepro_core::sqlite_affinity_decimal(text) {
        return Some(Value::Decimal(decimal));
    }
    (!tablepro_core::is_numeric_input(text)).then(|| Value::Text(text.to_owned()))
}

fn parse_special_driver_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    parse_mssql_datetimeoffset_input(text, col, driver_id)
        .or_else(|| parse_mongodb_integer_input(text, col, driver_id))
        .or_else(|| parse_mysql_spatial_input(col, driver_id))
        .or_else(|| {
            (driver_id == "postgres" && col.is_some_and(|column| is_postgres_numeric_type(&column.data_type))).then(
                || match text {
                    "NaN" | "Infinity" | "-Infinity" => Ok(Value::Text(text.into())),
                    _ => match parse_decimal_value(text) {
                        Ok(value) => Ok(value),
                        Err(_) if is_postgres_numeric_literal(text) => Ok(Value::Text(text.into())),
                        Err(error) => Err(error),
                    },
                },
            )
        })
        .or_else(|| parse_postgres_extended_temporal_input(text, col, driver_id))
        .or_else(|| parse_duckdb_date_input(text, col, driver_id))
        .or_else(|| parse_mongodb_decimal_input(text, col, driver_id))
        .or_else(|| parse_mongodb_date_input(text, col, driver_id))
        .or_else(|| parse_duckdb_timestamptz_input(text, col, driver_id))
        .or_else(|| parse_duckdb_temporal_input(text, col, driver_id))
}

fn parse_mssql_datetimeoffset_input(
    text: &str,
    col: Option<&ColumnInfo>,
    driver_id: &str,
) -> Option<Result<Value, String>> {
    if driver_id != "mssql" {
        return None;
    }
    let column = col?;
    let data_type = column.data_type.trim().to_ascii_lowercase();
    let suffix = data_type.strip_prefix("datetimeoffset")?;
    let scale = if suffix.is_empty() {
        Some(7)
    } else {
        suffix
            .strip_prefix('(')
            .and_then(|scale| scale.strip_suffix(')'))
            .and_then(|scale| scale.parse::<u8>().ok())
            .filter(|scale| *scale <= 7)
    };
    let Some(scale) = scale else {
        return Some(Err(crate::tr!("Invalid SQL Server datetimeoffset column scale")));
    };
    let parsed = chrono::DateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f %:z");
    Some(parsed.map_or_else(
        |_| Err(crate::tr!("Invalid SQL Server datetimeoffset")),
        |value| {
            let local = text.rsplit_once(' ').map_or(text, |(local, _)| local);
            let fraction_digits = local.split_once('.').map_or(0, |(_, fraction)| fraction.len());
            let offset_seconds = value.offset().local_minus_utc().abs();
            let local_year = value.date_naive().year();
            let utc_year = value.naive_utc().date().year();
            if fraction_digits > usize::from(scale)
                || offset_seconds > 14 * 60 * 60
                || !(1..=9999).contains(&local_year)
                || !(1..=9999).contains(&utc_year)
            {
                return Err(crate::tr!(
                    "SQL Server datetimeoffset value exceeds the column precision or offset range"
                ));
            }
            Ok(Value::Text(text.to_owned()))
        },
    ))
}

pub(super) fn parse_input_for_grid_cell(
    text: &str,
    col: Option<&ColumnInfo>,
    driver_id: &str,
    current_value: Option<&Value>,
) -> Result<Value, String> {
    if text.is_empty()
        && driver_id == "sqlite"
        && col.is_some_and(|column| column.data_type.trim().eq_ignore_ascii_case("any"))
        && matches!(current_value, Some(Value::Text(_)))
    {
        return Ok(Value::Text(String::new()));
    }
    if col.is_some_and(|column| {
        let data_type = column.data_type.trim().to_ascii_lowercase();
        match driver_id {
            "duckdb" => data_type.starts_with("enum"),
            "clickhouse" => {
                let data_type = data_type.strip_prefix("nullable(").unwrap_or(&data_type);
                data_type.starts_with("enum8(") || data_type.starts_with("enum16(")
            }
            _ => false,
        }
    }) && let Some(label) = parse_sql_single_quoted_string(text.trim())
    {
        return Ok(Value::Text(label));
    }
    if !text.is_empty()
        && driver_id == "sqlite"
        && col.is_some_and(|column| column.data_type.trim().eq_ignore_ascii_case("any"))
    {
        match current_value {
            Some(Value::Int(_)) => return parse_int_value(text.trim()),
            Some(Value::Float(_)) => return parse_float_value(text.trim()),
            Some(Value::Text(_)) => return Ok(Value::Text(text.to_owned())),
            _ => {}
        }
        // A NULL or draft cell has no runtime kind to preserve. Keep its
        // non-empty input as text instead of guessing that numeric-looking
        // text means the user intended a different storage class.
    }
    parse_input_for_driver(text, col, driver_id)
}

fn parse_sql_single_quoted_string(text: &str) -> Option<String> {
    if text.len() < 2 {
        return None;
    }
    let inner = text.strip_prefix('\'')?.strip_suffix('\'')?;
    let mut label = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\'' {
            label.push(ch);
            continue;
        }
        if chars.next()? != '\'' {
            return None;
        }
        label.push('\'');
    }
    Some(label)
}

fn parse_postgres_extended_temporal_input(
    text: &str,
    col: Option<&ColumnInfo>,
    driver_id: &str,
) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "postgres" {
        return None;
    }
    let kind = column.data_type.trim().to_ascii_lowercase();
    if kind == "date" {
        if parse_date_value(text).is_ok() {
            return None;
        }
        return Some(if extended_duckdb_date(text).is_some() {
            Ok(Value::Text(text.to_owned()))
        } else {
            Err(crate::tr!("Invalid date. Use YYYY-MM-DD."))
        });
    }
    if matches!(kind.as_str(), "timestamp" | "timestamp without time zone") {
        if parse_datetime_value(text).is_ok() {
            return None;
        }
        return Some(match extended_duckdb_timestamp_nanos(text) {
            Some(nanos) if nanos % 1_000 == 0 => Ok(Value::Text(text.replace('T', " "))),
            _ => Err(crate::tr!("Invalid datetime. Use YYYY-MM-DD HH:MM:SS.")),
        });
    }
    if matches!(kind.as_str(), "timestamptz" | "timestamp with time zone") {
        if parse_timestamptz_value(text).is_ok() {
            return None;
        }
        return Some(
            tablepro_core::import::duckdb_extended_timestamptz_nanos(text)
                .filter(|nanos| nanos % 1_000 == 0)
                .map(|_| Value::Text(text.replace('T', " ")))
                .ok_or_else(|| crate::tr!("Invalid timestamp with time zone.")),
        );
    }
    None
}

fn parse_mysql_spatial_input(col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    if driver_id != "mysql" {
        return None;
    }
    let data_type = col?.data_type.trim().to_ascii_lowercase();
    let base = data_type.split('(').next()?.trim();
    matches!(
        base,
        "geometry"
            | "point"
            | "linestring"
            | "polygon"
            | "multipoint"
            | "multilinestring"
            | "multipolygon"
            | "geometrycollection"
    )
    .then(|| Err(crate::tr!("MySQL spatial values cannot be edited losslessly")))
}

fn parse_mysql_integer_input(text: &str, col: Option<&ColumnInfo>) -> Option<Result<Value, String>> {
    let data_type = col?.data_type.trim().to_ascii_lowercase();
    let zerofill = data_type.strip_suffix(" zerofill");
    let data_type = zerofill.unwrap_or(&data_type);
    let unsigned = data_type.ends_with(" unsigned") || zerofill.is_some();
    let base = data_type
        .strip_suffix(" unsigned")
        .unwrap_or(data_type)
        .split('(')
        .next()?;

    // MySQL exposes TINYINT(1) as the app's boolean editing contract when
    // it is signed. Preserve that behavior; an UNSIGNED declaration uses
    // its actual numeric range and is handled below.
    if !unsigned && base == "tinyint" && data_type.contains("(1)") {
        return None;
    }

    let (minimum, maximum) = match (base, unsigned) {
        ("tinyint", false) => (i128::from(i8::MIN), i128::from(i8::MAX)),
        ("tinyint", true) => (0, i128::from(u8::MAX)),
        ("smallint", false) => (i128::from(i16::MIN), i128::from(i16::MAX)),
        ("smallint", true) => (0, i128::from(u16::MAX)),
        ("mediumint", false) => (-8_388_608, 8_388_607),
        ("mediumint", true) => (0, 16_777_215),
        ("int" | "integer", false) => (i128::from(i32::MIN), i128::from(i32::MAX)),
        ("int" | "integer", true) => (0, i128::from(u32::MAX)),
        ("bigint", true) => (0, i128::from(u64::MAX)),
        _ => return None,
    };
    Some((|| {
        let value = text.parse::<i128>().map_err(|_| crate::tr!("Invalid integer"))?;
        if !(minimum..=maximum).contains(&value) {
            return Err(crate::tr!("Integer is outside the supported MySQL column range"));
        }
        Ok(i64::try_from(value).map_or_else(|_| Value::Text(value.to_string()), Value::Int))
    })())
}

fn parse_mongodb_integer_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "mongodb" {
        return None;
    }
    match column.data_type.trim().to_ascii_lowercase().as_str() {
        "int" => Some(text.parse::<i32>().map_or_else(
            |_| Err(crate::tr!("Integer is outside the supported MongoDB Int32 range")),
            |value| Ok(Value::Json(serde_json::json!({"$numberInt": value.to_string()}))),
        )),
        "long" => Some(parse_int_value(text)),
        _ => None,
    }
}

fn parse_mongodb_decimal_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "mongodb" || !column.data_type.trim().eq_ignore_ascii_case("decimal") {
        return None;
    }
    if let Ok(value) = parse_decimal_value(text) {
        return Some(Ok(value));
    }
    Some(
        drivers_mongodb::canonical_decimal128_text(text)
            .map(|canonical| Value::Json(serde_json::json!({"$numberDecimal": canonical})))
            .map_err(|_| crate::tr!("Invalid decimal")),
    )
}

fn parse_mongodb_date_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "mongodb" || !column.data_type.trim().eq_ignore_ascii_case("date") {
        return None;
    }
    let timestamp = chrono::DateTime::parse_from_rfc3339(text).ok()?;
    Some(if timestamp.timestamp_subsec_nanos() % 1_000_000 == 0 {
        Ok(Value::TimestampTz(timestamp.to_utc()))
    } else {
        Err(crate::tr!("MongoDB BSON dates support millisecond precision only"))
    })
}

fn is_postgres_numeric_type(data_type: &str) -> bool {
    let data_type = data_type.trim().to_ascii_lowercase();
    matches!(data_type.as_str(), "numeric" | "decimal")
        || data_type.starts_with("numeric(")
        || data_type.starts_with("decimal(")
}

fn is_duckdb_timestamptz_type(data_type: &str) -> bool {
    matches!(
        data_type.trim().to_ascii_lowercase().as_str(),
        "timestamptz" | "timestamp with time zone"
    )
}

fn parse_duckdb_timestamptz_input(
    text: &str,
    col: Option<&ColumnInfo>,
    driver_id: &str,
) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "duckdb" || !is_duckdb_timestamptz_type(&column.data_type) {
        return None;
    }
    Some((|| {
        if let Ok(Value::TimestampTz(timestamp)) = parse_timestamptz_value(text) {
            if timestamp.timestamp_subsec_nanos() % 1_000 != 0 {
                return Err(crate::tr!("DuckDB TIMESTAMPTZ supports microsecond precision only"));
            }
            return Ok(Value::TimestampTz(timestamp));
        }
        let Some(nanos) = tablepro_core::import::duckdb_extended_timestamptz_nanos(text) else {
            return Err(crate::tr!("Invalid timestamp with time zone."));
        };
        if nanos % 1_000 != 0 {
            return Err(crate::tr!("DuckDB TIMESTAMPTZ supports microsecond precision only"));
        }
        Ok(Value::Text(text.to_owned()))
    })())
}

fn parse_duckdb_temporal_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    let column = col?;
    if driver_id != "duckdb" {
        return None;
    }
    let data_type = column.data_type.trim().to_ascii_lowercase();
    let (quantum_ns, kind) = match data_type.as_str() {
        "time" | "time without time zone" => (1_000, "TIME"),
        "timestamp" | "timestamp without time zone" => (1_000, "TIMESTAMP"),
        "timestamp_s" => (1_000_000_000, "TIMESTAMP_S"),
        "timestamp_ms" => (1_000_000, "TIMESTAMP_MS"),
        _ => return None,
    };
    Some((|| {
        let (value, nanos) = if kind == "TIME" {
            match parse_time_value(text)? {
                Value::Time(value) => {
                    let nanos = value.nanosecond();
                    (Value::Time(value), nanos)
                }
                _ => return Err(crate::tr!("Invalid time.")),
            }
        } else if let Ok(Value::DateTime(value)) = parse_datetime_value(text) {
            let nanos = value.nanosecond();
            (Value::DateTime(value), nanos)
        } else if let Some(nanos) = extended_duckdb_timestamp_nanos(text) {
            (Value::Text(text.to_owned()), nanos)
        } else {
            return Err(crate::tr!("Invalid date and time."));
        };
        if nanos % quantum_ns != 0 {
            return Err(format!("DuckDB {kind} precision cannot represent this value exactly"));
        }
        Ok(value)
    })())
}

fn parse_duckdb_date_input(text: &str, col: Option<&ColumnInfo>, driver_id: &str) -> Option<Result<Value, String>> {
    if driver_id != "duckdb" || !col?.data_type.trim().eq_ignore_ascii_case("date") {
        return None;
    }
    if parse_date_value(text).is_ok() {
        return None;
    }
    Some(if extended_duckdb_date(text).is_some() {
        Ok(Value::Text(text.to_owned()))
    } else {
        Err(crate::tr!("Invalid date. Use YYYY-MM-DD."))
    })
}

fn extended_duckdb_timestamp_nanos(text: &str) -> Option<u32> {
    let (date, time) = if let Some((date, time)) = text.split_once(" (BC) ") {
        (format!("{date} (BC)"), time)
    } else {
        let (date, time) = text.split_once(' ')?;
        (date.to_owned(), time)
    };
    extended_duckdb_date(&date)?;
    let Value::Time(time) = parse_time_value(time).ok()? else {
        return None;
    };
    Some(time.nanosecond())
}

fn extended_duckdb_date(text: &str) -> Option<(i64, u32, u32, bool)> {
    let (date, bc) = text.strip_suffix(" (BC)").map_or((text, false), |date| (date, true));
    let mut parts = date.split('-');
    let year_text = parts.next()?;
    if year_text.len() < 4 || !year_text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let year = year_text.parse::<i64>().ok()?;
    let month = parts.next()?.parse::<u32>().ok()?;
    let day = parts.next()?.parse::<u32>().ok()?;
    if parts.next().is_some() || year == 0 || month == 0 || month > 12 {
        return None;
    }
    let astronomical_year = if bc { 1 - year } else { year };
    let leap = astronomical_year.rem_euclid(4) == 0
        && (astronomical_year.rem_euclid(100) != 0 || astronomical_year.rem_euclid(400) == 0);
    let days_in_month = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    (day > 0 && day <= days_in_month && (bc || year > 9999)).then_some((year, month, day, bc))
}

fn is_postgres_numeric_literal(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut cursor = usize::from(bytes.first().is_some_and(|byte| matches!(*byte, b'+' | b'-')));
    let integer_start = cursor;
    while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
        cursor += 1;
    }
    let has_integer = cursor > integer_start;
    let mut has_fraction = false;
    if bytes.get(cursor) == Some(&b'.') {
        cursor += 1;
        let fraction_start = cursor;
        while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        has_fraction = cursor > fraction_start;
    }
    if !has_integer && !has_fraction {
        return false;
    }
    if matches!(bytes.get(cursor), Some(b'e' | b'E')) {
        cursor += 1;
        if matches!(bytes.get(cursor), Some(b'+' | b'-')) {
            cursor += 1;
        }
        let exponent_start = cursor;
        while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        if cursor == exponent_start {
            return false;
        }
    }
    cursor == bytes.len()
}

fn mysql_bit_width(data_type: &str) -> Option<u32> {
    data_type
        .strip_prefix("bit(")?
        .strip_suffix(')')?
        .parse::<u32>()
        .ok()
        .filter(|width| (1..=64).contains(width))
}

fn parse_mysql_bit_value(text: &str, width: u32) -> Result<Value, String> {
    if width == 1 {
        return parse_bool_value(text);
    }
    let number = text.parse::<u64>().map_err(|_| crate::tr!("Invalid integer"))?;
    let maximum = if width == 64 {
        i64::MAX as u64
    } else {
        (1u64 << width) - 1
    };
    if number > maximum {
        return Err(crate::tr!("Integer is outside the supported BIT range"));
    }
    Ok(Value::Int(number as i64))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TypeKind {
    Bool,
    Int,
    Float,
    Decimal,
    Uuid,
    Json,
    TimestampTz,
    DateTime,
    Date,
    Time,
    Text,
}

/// Map a lowercased `data_type` string to a coarse `TypeKind`. Order
/// of checks matters because several SQL types share substrings — for
/// example `timestamptz` / `timestamp with time zone` must be matched
/// before bare `timestamp`, and `tinyint(1)` (MySQL bool) must be
/// matched before generic `tinyint` / `int` patterns.
pub(super) fn classify_type(dt: &str) -> TypeKind {
    // PostgreSQL arrays arrive as their textual array literal. Classifying
    // by the element name (for example `uuid[]` or `date[]`) would feed the
    // whole literal to a scalar parser and reject valid grid edits.
    if dt.trim_end().ends_with("[]") {
        return TypeKind::Text;
    }
    if let Some(kind) = classify_bool_or_bit(dt) {
        return kind;
    }
    if dt.contains("uuid") {
        return TypeKind::Uuid;
    }
    if is_json_like(dt) {
        return TypeKind::Json;
    }
    if let Some(kind) = classify_temporal(dt) {
        return kind;
    }
    classify_numeric(dt).unwrap_or(TypeKind::Text)
}

// Postgres `format_type()` returns "bit(1)" for length-1 BIT columns
// (not the bare "bit" the original guard expected). Both forms classify
// as Bool so the cell renders as a checkbox rather than a text editor
// that rejects "true"/"false" with "Invalid integer". Wider BIT(n)
// values are integers.
fn classify_bool_or_bit(dt: &str) -> Option<TypeKind> {
    if matches!(dt, "bool" | "boolean" | "bit" | "bit(1)" | "tinyint(1)") {
        return Some(TypeKind::Bool);
    }
    if dt.starts_with("bit(") {
        return Some(TypeKind::Int);
    }
    None
}

fn is_json_like(dt: &str) -> bool {
    dt.contains("json")
        || dt.starts_with("bindata-subtype-")
        || matches!(
            dt,
            "object"
                | "array"
                | "objectid"
                | "bsontimestamp"
                | "regex"
                | "javascript"
                | "javascriptwithscope"
                | "symbol"
                | "undefined"
                | "dbpointer"
                | "minkey"
                | "maxkey"
        )
}

fn classify_temporal(dt: &str) -> Option<TypeKind> {
    if dt.contains("timestamptz") || dt.contains("with time zone") {
        return Some(TypeKind::TimestampTz);
    }
    if dt.contains("timestamp") || dt.contains("datetime") {
        return Some(TypeKind::DateTime);
    }
    if dt == "date" || (dt.starts_with("date") && !dt.contains("datetime") && !dt.contains("time")) {
        return Some(TypeKind::Date);
    }
    if dt == "time" || dt.starts_with("time(") || dt == "time without time zone" {
        return Some(TypeKind::Time);
    }
    None
}

fn classify_numeric(dt: &str) -> Option<TypeKind> {
    if matches!(dt, "decimal" | "numeric" | "money") || dt.starts_with("decimal(") || dt.starts_with("numeric(") {
        return Some(TypeKind::Decimal);
    }
    if matches!(dt, "float" | "double" | "real" | "double precision") || dt.starts_with("float(") {
        return Some(TypeKind::Float);
    }
    if is_integer_type(dt) {
        return Some(TypeKind::Int);
    }
    None
}

fn is_integer_type(dt: &str) -> bool {
    matches!(
        dt,
        "int"
            | "int2"
            | "int4"
            | "int8"
            | "integer"
            | "smallint"
            | "bigint"
            | "tinyint"
            | "mediumint"
            | "serial"
            | "bigserial"
            | "smallserial"
    ) || dt.starts_with("int(")
        || dt.starts_with("integer(")
        || dt.starts_with("smallint(")
        || dt.starts_with("bigint(")
        || dt.starts_with("tinyint(")
        || dt.starts_with("mediumint(")
}

pub(super) fn parse_bool_value(text: &str) -> Result<Value, String> {
    match text.to_ascii_lowercase().as_str() {
        "true" | "t" | "1" | "yes" | "y" | "on" => Ok(Value::Bool(true)),
        "false" | "f" | "0" | "no" | "n" | "off" => Ok(Value::Bool(false)),
        _ => Err(crate::tr!("Invalid boolean. Use true/false, yes/no, or 1/0.")),
    }
}

pub(super) fn parse_int_value(text: &str) -> Result<Value, String> {
    text.parse::<i64>()
        .map(Value::Int)
        .map_err(|_| crate::tr!("Invalid integer"))
}

pub(super) fn parse_float_value(text: &str) -> Result<Value, String> {
    tablepro_core::parse_float_input(text)
        .map(Value::Float)
        .map_err(|_| crate::tr!("Invalid number"))
}

pub(super) fn parse_decimal_value(text: &str) -> Result<Value, String> {
    rust_decimal::Decimal::from_str_exact(text)
        .map(Value::Decimal)
        .map_err(|_| crate::tr!("Invalid decimal"))
}

pub(super) fn parse_uuid_value(text: &str) -> Result<Value, String> {
    uuid::Uuid::parse_str(text)
        .map(Value::Uuid)
        .map_err(|_| crate::tr!("Invalid UUID. Expected 8-4-4-4-12 hex digits."))
}

pub(super) fn parse_json_value(text: &str) -> Result<Value, String> {
    serde_json::from_str::<serde_json::Value>(text)
        .map(Value::Json)
        .map_err(|e| crate::tr!("Invalid JSON: {error}").replace("{error}", &e.to_string()))
}

pub(super) fn parse_timestamptz_value(text: &str) -> Result<Value, String> {
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(text) {
        return Ok(Value::TimestampTz(dt.with_timezone(&chrono::Utc)));
    }
    Err(crate::tr!(
        "Invalid timestamp. Use ISO 8601, e.g. 2024-01-15T14:30:00Z."
    ))
}

pub(super) fn parse_datetime_value(text: &str) -> Result<Value, String> {
    let formats = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%dT%H:%M:%S%.f",
    ];
    for fmt in &formats {
        if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(text, fmt) {
            return Ok(Value::DateTime(dt));
        }
    }
    Err(crate::tr!("Invalid datetime. Use YYYY-MM-DD HH:MM:SS."))
}

pub(super) fn parse_date_value(text: &str) -> Result<Value, String> {
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .map(Value::Date)
        .map_err(|_| crate::tr!("Invalid date. Use YYYY-MM-DD."))
}

pub(super) fn parse_time_value(text: &str) -> Result<Value, String> {
    let formats = ["%H:%M:%S", "%H:%M:%S%.f", "%H:%M"];
    for fmt in &formats {
        if let Ok(t) = chrono::NaiveTime::parse_from_str(text, fmt) {
            return Ok(Value::Time(t));
        }
    }
    Err(crate::tr!("Invalid time. Use HH:MM:SS."))
}

#[cfg(test)]
#[path = "../../../../core/tests/support/parser_contract.rs"]
mod parser_contract;

#[cfg(test)]
#[path = "../../../tests/support/value_parse.rs"]
mod tests;

#[cfg(test)]
#[path = "../../../tests/support/sqlite_any_contract.rs"]
mod sqlite_any_contract;

#[cfg(test)]
#[path = "../../../tests/support/duckdb_enum_contract.rs"]
mod duckdb_enum_contract;

#[cfg(test)]
#[path = "../../../tests/support/clickhouse_enum_contract.rs"]
mod clickhouse_enum_contract;

#[cfg(test)]
#[path = "../../../tests/support/mysql_integer_contract.rs"]
mod mysql_integer_contract;

#[cfg(test)]
#[path = "../../../tests/support/mysql_enum_set_contract.rs"]
mod mysql_enum_set_contract;

#[cfg(test)]
#[path = "../../../tests/support/mysql_temporal_contract.rs"]
mod mysql_temporal_contract;

#[cfg(test)]
#[path = "../../../tests/support/mssql_legacy_datetime_contract.rs"]
mod mssql_legacy_datetime_contract;

#[cfg(test)]
#[path = "../../../tests/support/mssql_datetimeoffset_contract.rs"]
mod mssql_datetimeoffset_contract;

#[cfg(test)]
#[path = "../../../tests/support/mssql_max_value_contract.rs"]
mod mssql_max_value_contract;

#[cfg(test)]
#[path = "../../../tests/support/mssql_server_owned_columns.rs"]
mod mssql_server_owned_columns;

#[cfg(test)]
#[path = "../../../tests/support/mysql_spatial_contract.rs"]
mod mysql_spatial_contract;

#[cfg(test)]
#[path = "../../../tests/support/postgres_array_contract.rs"]
mod postgres_array_contract;

#[cfg(test)]
#[path = "../../../tests/support/postgres_bit_array_grid.rs"]
mod postgres_bit_array_grid;

#[cfg(test)]
#[path = "../../../tests/support/postgres_citext_array_grid.rs"]
mod postgres_citext_array_grid;

#[cfg(test)]
#[path = "../../../tests/support/mongodb_nested_edit_contract.rs"]
mod mongodb_nested_edit_contract;

#[cfg(test)]
#[path = "../../../tests/support/mongodb_integer_width.rs"]
mod mongodb_integer_width;
