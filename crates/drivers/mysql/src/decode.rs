use sqlx::mysql::MySqlRow;
use sqlx::{Column, Row, TypeInfo, ValueRef};
use tablepro_core::{Value, single_precision_as_f64};

use crate::{packed, temporal};

pub(crate) fn extract_value(row: &MySqlRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    match row.try_get_raw(idx) {
        Ok(raw) if raw.is_null() => zero_calendar(raw, &type_name).unwrap_or(Value::Null),
        Ok(_) => decode_by_type(row, idx, &type_name).unwrap_or_else(|| undecodable(idx, &type_name)),
        Err(_) => undecodable(idx, &type_name),
    }
}

fn decode_by_type(row: &MySqlRow, idx: usize, type_name: &str) -> Option<Value> {
    match type_name {
        "TINYINT" | "SMALLINT" | "INT" | "MEDIUMINT" | "BIGINT" => row.try_get::<i64, _>(idx).map(Value::Int).ok(),
        // sqlx's i64 decoder refuses an UNSIGNED-flagged column
        // outright (a distinct type-compatibility class, not just the
        // same decode with a wider range), so every one of these
        // columns read back as an empty cell regardless of value --
        // decode as u64 instead, and keep BIGINT UNSIGNED's digits as
        // text on the rare value that exceeds i64::MAX.
        "TINYINT UNSIGNED" | "SMALLINT UNSIGNED" | "INT UNSIGNED" | "MEDIUMINT UNSIGNED" | "BIGINT UNSIGNED" => row
            .try_get::<u64, _>(idx)
            .map(|v| i64::try_from(v).map_or_else(|_| Value::Text(v.to_string()), Value::Int))
            .ok(),
        "FLOAT" => row
            .try_get::<f32, _>(idx)
            .map(|v| Value::Float(single_precision_as_f64(v)))
            .ok(),
        "DOUBLE" => row.try_get::<f64, _>(idx).map(Value::Float).ok(),
        // DECIMAL/NUMERIC arrive over the wire as text, but sqlx only
        // decodes that text into rust_decimal::Decimal, which caps out
        // at ~28-29 significant digits -- well inside what MySQL
        // itself allows (up to 65). A legitimately large value keeps
        // its exact digits as text instead of the row's real number
        // silently disappearing.
        "DECIMAL" | "NUMERIC" => decode_decimal_exact(row, idx),
        "BOOLEAN" => row.try_get::<bool, _>(idx).map(Value::Bool).ok(),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .ok()
            .or_else(|| temporal::calendar_text(row.try_get_raw(idx).ok()?, false)),
        "TIME" => temporal::time_value(row.try_get_raw(idx).ok()?),
        "DATETIME" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .ok()
            .or_else(|| temporal::calendar_text(row.try_get_raw(idx).ok()?, true)),
        "YEAR" => temporal::year_value(row.try_get_raw(idx).ok()?),
        "BIT" => packed::bit_value(row.try_get_raw(idx).ok()?),
        "GEOMETRY" => packed::geometry_value(row.try_get_raw(idx).ok()?),
        "ENUM" | "SET" => row
            .try_get::<String, _>(idx)
            .map(Value::Text)
            .or_else(|_| row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes))
            .ok(),
        "TIMESTAMP" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz)
            .ok(),
        "JSON" => row.try_get::<serde_json::Value, _>(idx).map(Value::Json).ok(),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "VARBINARY" | "BINARY" => {
            row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes).ok()
        }
        _ => row.try_get::<String, _>(idx).map(Value::Text).ok(),
    }
}

fn zero_calendar(raw: sqlx::mysql::MySqlValueRef<'_>, type_name: &str) -> Option<Value> {
    match type_name {
        "DATE" => temporal::calendar_text(raw, false),
        "DATETIME" | "TIMESTAMP" => temporal::calendar_text(raw, true),
        _ => None,
    }
}

fn undecodable(idx: usize, type_name: &str) -> Value {
    tracing::warn!(
        column_index = idx + 1,
        type_name,
        "mysql column value could not be decoded; showing it as undecodable"
    );
    Value::Undecodable(type_name.to_string())
}

/// `String`'s `Type<MySql>` compatibility check refuses a DECIMAL
/// column outright, even though its wire representation is already
/// text -- decoding through the raw value ref bypasses that check
/// instead of going through `Row::try_get`.
fn decode_decimal_exact(row: &MySqlRow, idx: usize) -> Option<Value> {
    let raw = row.try_get_raw(idx).ok()?;
    if raw.is_null() {
        return None;
    }
    <&str as sqlx::Decode<sqlx::MySql>>::decode(raw)
        .map(|text| {
            rust_decimal::Decimal::from_str_exact(text)
                .map(Value::Decimal)
                .unwrap_or_else(|_| Value::Text(text.to_owned()))
        })
        .ok()
}
