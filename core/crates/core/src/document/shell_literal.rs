use chrono::{DateTime, Datelike};

use crate::column::ColumnType;
use crate::dialect::LiteralError;
use crate::meta::TableRef;
use crate::sql_syntax::mongo::{ShellConstructor, ShellNumber, ShellValue, parse_value};
use crate::value::{JsonText, Temporal, Value};

use super::document_read::collection;

/// A value as shell text that reads back as the same value and type: a
/// copied document and an exported row can be run again as they are.
pub fn shell_literal(value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
    let quoted = |text: &str| ShellValue::string(text).to_string();
    Ok(match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Int32(number) => number.to_string(),
        Value::Int(number) => match (column.name.as_str(), i32::try_from(*number)) {
            ("int", Ok(small)) => small.to_string(),
            _ => format!("NumberLong({})", quoted(&number.to_string())),
        },
        Value::UInt(number) => match i64::try_from(*number) {
            Ok(number) => format!("NumberLong({})", quoted(&number.to_string())),
            Err(_) => format!("NumberDecimal({})", quoted(&number.to_string())),
        },
        Value::WideInt(number) => format!("NumberDecimal({})", quoted(&number.to_string())),
        Value::Decimal(number) => format!("NumberDecimal({})", quoted(&number.to_string())),
        Value::Float64(number) => double(*number).to_string(),
        Value::Float32(number) => double(f64::from(*number)).to_string(),
        Value::Text(text) => quoted(text),
        Value::Json(json) => json_literal(json).ok_or(LiteralError::Unrepresentable {
            found: value.variant_name(),
        })?,
        Value::Uuid(uuid) => format!("UUID({})", quoted(&uuid.to_string())),
        Value::Bytes(bytes) => format!("BinData(0, {})", quoted(&super::json_cells::base64(bytes))),
        Value::TimestampTz(Temporal::Finite(stamp)) => format!(
            "ISODate({})",
            quoted(
                &stamp
                    .to_datetime()
                    .naive_utc()
                    .format("%Y-%m-%dT%H:%M:%S%.3fZ")
                    .to_string()
            )
        ),
        Value::Timestamp(Temporal::Finite(stamp)) => {
            format!(
                "ISODate({})",
                quoted(&stamp.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())
            )
        }
        Value::Date(Temporal::Finite(date)) => format!("ISODate({})", quoted(&date.format("%Y-%m-%d").to_string())),
        Value::Other(other) if other.type_name == "objectId" => format!("ObjectId({})", quoted(&other.text)),
        Value::Other(other) => quoted(&other.text),
        Value::Undecodable(undecodable) => {
            return Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            });
        }
        other => {
            return Err(LiteralError::Unrepresentable {
                found: other.variant_name(),
            });
        }
    })
}

/// Extended JSON written with the shell's helpers, at any depth, so
/// `{"$numberLong": "7"}` reaches mongosh as a long rather than as a
/// document with a `$numberLong` key.
fn json_literal(json: &JsonText) -> Option<String> {
    parse_value(json.as_str())
        .ok()
        .map(|value| with_helpers(value).to_string())
}

fn with_helpers(value: ShellValue) -> ShellValue {
    match value {
        ShellValue::Object(fields) => match fields.as_slice() {
            [(key, inner)] => wrapped(key, inner).unwrap_or_else(|| ShellValue::Object(helped_fields(fields))),
            _ => ShellValue::Object(helped_fields(fields)),
        },
        ShellValue::Array(items) => ShellValue::Array(items.into_iter().map(with_helpers).collect()),
        // A fraction or an exponent marks a double, which mongosh stores
        // as an int when it is whole.
        ShellValue::Number(number) if number.as_integer().is_none() => {
            number.as_f64().map_or(ShellValue::Number(number), double)
        }
        other => other,
    }
}

fn helped_fields(fields: Vec<(String, ShellValue)>) -> Vec<(String, ShellValue)> {
    fields
        .into_iter()
        .map(|(key, value)| (key, with_helpers(value)))
        .collect()
}

/// The helper an Extended JSON wrapper stands for, or `None` for a
/// document or a wrapper the shell has no helper for, such as `$symbol`.
fn wrapped(key: &str, inner: &ShellValue) -> Option<ShellValue> {
    let text = inner.as_str();
    let helper = |kind, args| Some(ShellValue::Constructor { kind, args });
    match key {
        "$oid" => text
            .filter(|hex| hex.len() == 24 && hex.bytes().all(|digit| digit.is_ascii_hexdigit()))
            .and_then(|hex| helper(ShellConstructor::ObjectId, vec![ShellValue::string(hex)])),
        "$numberInt" => {
            let number = text?.parse::<i32>().ok()?;
            helper(ShellConstructor::Int32, vec![ShellValue::integer(number.into())])
        }
        "$numberLong" => {
            let number = text?.parse::<i64>().ok()?;
            helper(ShellConstructor::Int64, vec![ShellValue::string(number.to_string())])
        }
        "$numberDouble" => Some(double(ShellNumber::new(text?).as_f64()?)),
        "$numberDecimal" => helper(ShellConstructor::Decimal128, vec![ShellValue::string(text?)]),
        "$date" => date(inner),
        "$binary" => binary(inner),
        "$uuid" => text
            .filter(|uuid| uuid::Uuid::parse_str(uuid).is_ok())
            .and_then(|uuid| helper(ShellConstructor::Uuid, vec![ShellValue::string(uuid)])),
        "$timestamp" => {
            let part = |name| match inner.field(name) {
                Some(ShellValue::Number(number)) => number.as_integer().filter(|part| u32::try_from(*part).is_ok()),
                _ => None,
            };
            let args = vec![ShellValue::integer(part("t")?), ShellValue::integer(part("i")?)];
            helper(ShellConstructor::Timestamp, args)
        }
        "$regularExpression" => Some(regex(
            inner.field("pattern")?.as_str()?,
            inner.field("options")?.as_str()?,
        )),
        "$minKey" => helper(ShellConstructor::MinKey, Vec::new()),
        "$maxKey" => helper(ShellConstructor::MaxKey, Vec::new()),
        "$code" => helper(ShellConstructor::Code, vec![ShellValue::string(text?)]),
        _ => None,
    }
}

/// `ISODate` of the ISO text, or of milliseconds for a date mongosh's
/// ISO form cannot spell, before year 0 or past 9999.
fn date(inner: &ShellValue) -> Option<ShellValue> {
    let millis = match inner {
        ShellValue::String(text) => return Some(iso_date(ShellValue::string(text))),
        ShellValue::Number(number) => number.as_integer()?,
        _ => match inner.as_object()? {
            [(key, ShellValue::String(digits))] if key == "$numberLong" => digits.parse().ok()?,
            _ => return None,
        },
    };
    let argument = match DateTime::from_timestamp_millis(millis).filter(|date| (0..=9999).contains(&date.year())) {
        Some(date) => ShellValue::string(date.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()),
        None => ShellValue::integer(millis),
    };
    Some(iso_date(argument))
}

fn iso_date(argument: ShellValue) -> ShellValue {
    ShellValue::Constructor {
        kind: ShellConstructor::Date,
        args: vec![argument],
    }
}

/// `UUID()` for a UUID, subtype 4, and `BinData()` for any other bytes.
fn binary(inner: &ShellValue) -> Option<ShellValue> {
    let base64 = inner.field("base64")?.as_str()?;
    let subtype = u8::from_str_radix(inner.field("subType")?.as_str()?, 16).ok()?;
    let uuid = (subtype == 4)
        .then(|| super::json_cells::base64_bytes(base64))
        .flatten()
        .and_then(|bytes| uuid::Uuid::from_slice(&bytes).ok());
    let (kind, args) = match uuid {
        Some(uuid) => (ShellConstructor::Uuid, vec![ShellValue::string(uuid.to_string())]),
        None => (
            ShellConstructor::BinData,
            vec![ShellValue::integer(subtype.into()), ShellValue::string(base64)],
        ),
    };
    Some(ShellValue::Constructor { kind, args })
}

/// `BSONRegExp()`, which mongosh stores as the pattern and options
/// given. A literal or `RegExp()` is a JavaScript expression first, which
/// drops `s` and refuses `x`, `l` and patterns only PCRE reads.
fn regex(pattern: &str, options: &str) -> ShellValue {
    ShellValue::Constructor {
        kind: ShellConstructor::BsonRegExp,
        args: vec![ShellValue::string(pattern), ShellValue::string(options)],
    }
}

/// A double as text mongosh stores as one. It stores a whole number in
/// the int32 range, `-0` among them, as an int, so that one goes in
/// `Double()`; any other keeps a fraction or an exponent.
fn double(number: f64) -> ShellValue {
    let text = if number.is_nan() {
        "NaN".to_owned()
    } else if number.is_infinite() {
        if number < 0.0 { "-Infinity" } else { "Infinity" }.to_owned()
    } else if number.fract() == 0.0 && (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&number) {
        return ShellValue::Constructor {
            kind: ShellConstructor::Double,
            args: vec![ShellValue::Number(ShellNumber::new(format!("{number}")))],
        };
    } else {
        let text = format!("{number:?}");
        match text.contains(['.', 'e', 'E']) {
            true => text,
            false => format!("{text}.0"),
        }
    };
    ShellValue::Number(ShellNumber::new(text))
}

/// What every row's `insertOne` shares, up to its document.
pub(crate) fn insert_start(table: &TableRef) -> String {
    format!("{}.insertOne(", collection(table))
}

/// One row as the document an `insertOne` takes, its fields in order.
pub(crate) fn insert_document(fields: &[(String, String)]) -> String {
    let fields: Vec<String> = fields
        .iter()
        .map(|(name, literal)| format!("{}: {literal}", ShellValue::string(name)))
        .collect();
    format!("{{{}}}", fields.join(", "))
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnKind, ReadForm};
    use crate::sql_syntax::mongo::parse_value;
    use crate::value::{JsonText, OffsetTimestamp, OtherValue};

    use super::*;

    fn typed(name: &str) -> ColumnType {
        ColumnType {
            name: name.to_owned(),
            kind: ColumnKind::Other,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    #[test]
    fn a_literal_reads_back_as_its_type() {
        let at = chrono::DateTime::parse_from_rfc3339("2024-01-02T03:04:05.006+07:00").unwrap();
        let cases = [
            (Value::Int(5), "int", "5"),
            (Value::Int(5), "long", r#"NumberLong("5")"#),
            (Value::Int(5_000_000_000), "int", r#"NumberLong("5000000000")"#),
            (Value::Int32(5), "long", "5"),
            (Value::Int(5), "double", r#"NumberLong("5")"#),
            (Value::Int(5), "mixed", r#"NumberLong("5")"#),
            (Value::Float64(2.0), "double", "Double(2)"),
            (Value::Float64(-0.0), "double", "Double(-0)"),
            (Value::Float64(-2_147_483_648.0), "double", "Double(-2147483648)"),
            (Value::Float64(2_147_483_648.0), "double", "2147483648.0"),
            (Value::Float64(2.5), "double", "2.5"),
            (Value::Float64(1e300), "double", "1e300"),
            (Value::Float32(3.0), "double", "Double(3)"),
            (Value::Text("a\"b".to_owned()), "string", r#""a\"b""#),
            (
                Value::Other(Box::new(OtherValue {
                    type_name: "objectId".to_owned(),
                    text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
                })),
                "objectId",
                r#"ObjectId("5f1d7a0c9b1e8b2a3c4d5e6f")"#,
            ),
            (
                Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(at))),
                "date",
                r#"ISODate("2024-01-01T20:04:05.006Z")"#,
            ),
            (
                Value::Json(JsonText::parse(r#"{"a": {"$numberLong": "1"}}"#.to_owned()).unwrap()),
                "object",
                r#"{"a": NumberLong("1")}"#,
            ),
            (Value::Null, "string", "null"),
        ];
        for (value, column, expected) in cases {
            let literal = shell_literal(&value, &typed(column)).expect("a literal");
            assert_eq!(literal, expected);
            assert!(parse_value(&literal).is_ok(), "{literal}");
        }
        assert!(shell_literal(&Value::Array(Vec::new()), &typed("array")).is_err());
    }

    #[test]
    fn extended_json_is_written_with_the_shell_helpers_at_any_depth() {
        let cases = [
            (r#"{"$numberLong": "3000000000"}"#, r#"NumberLong("3000000000")"#),
            (r#"{"$numberInt": "-7"}"#, "NumberInt(-7)"),
            (r#"{"$numberDecimal": "9.99"}"#, r#"NumberDecimal("9.99")"#),
            (r#"{"$numberDouble": "NaN"}"#, "NaN"),
            (r#"{"$numberDouble": "Infinity"}"#, "Infinity"),
            (r#"{"$numberDouble": "-Infinity"}"#, "-Infinity"),
            (r#"{"$numberDouble": "2"}"#, "Double(2)"),
            (r#"{"$numberDouble": "-0.0"}"#, "Double(-0)"),
            (r#"{"$numberDouble": "0.5"}"#, "0.5"),
            (
                r#"{"$date": "2024-01-02T03:04:05.006Z"}"#,
                r#"ISODate("2024-01-02T03:04:05.006Z")"#,
            ),
            (
                r#"{"$date": {"$numberLong": "-315619200000"}}"#,
                r#"ISODate("1960-01-01T00:00:00.000Z")"#,
            ),
            (
                r#"{"$date": {"$numberLong": "253402300800000"}}"#,
                "ISODate(253402300800000)",
            ),
            (
                r#"{"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}"#,
                r#"ObjectId("5f1d7a0c9b1e8b2a3c4d5e6f")"#,
            ),
            (
                r#"{"$binary": {"base64": "VQ6EAOKbQdSnFkRmVUQAAA==", "subType": "04"}}"#,
                r#"UUID("550e8400-e29b-41d4-a716-446655440000")"#,
            ),
            (
                r#"{"$binary": {"base64": "aGkh", "subType": "80"}}"#,
                r#"BinData(128, "aGkh")"#,
            ),
            (
                r#"{"$timestamp": {"t": 1700000000, "i": 3}}"#,
                "Timestamp(1700000000, 3)",
            ),
            (
                r#"{"$regularExpression": {"pattern": "^a\\.b", "options": "i"}}"#,
                r#"BSONRegExp("^a\\.b", "i")"#,
            ),
            (
                r#"{"$regularExpression": {"pattern": "a/b", "options": "lsx"}}"#,
                r#"BSONRegExp("a/b", "lsx")"#,
            ),
            (r#"{"$minKey": 1}"#, "MinKey()"),
            (r#"{"$maxKey": 1}"#, "MaxKey()"),
            (
                r#"{"a": [{"$numberLong": "1"}, {"b": {"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}}], "c": 1.5}"#,
                r#"{"a": [NumberLong("1"), {"b": ObjectId("5f1d7a0c9b1e8b2a3c4d5e6f")}], "c": 1.5}"#,
            ),
            (
                r#"{"whole": 2.0, "zero": -0.0, "big": 3000000000.0, "tiny": 1e-7, "int": 2}"#,
                r#"{"whole": Double(2), "zero": Double(-0), "big": 3000000000.0, "tiny": 1e-7, "int": 2}"#,
            ),
            (r#"{"$numberLong": "x"}"#, r#"{"$numberLong": "x"}"#),
            (
                r#"{"$numberLong": "1", "b": {"$numberInt": "2"}}"#,
                r#"{"$numberLong": "1", "b": NumberInt(2)}"#,
            ),
            (r#"{"$symbol": "s"}"#, r#"{"$symbol": "s"}"#),
        ];
        for (json, expected) in cases {
            let cell = Value::Json(JsonText::parse(json.to_owned()).unwrap());

            let literal = shell_literal(&cell, &typed("mixed")).expect("a literal");

            assert_eq!(literal, expected, "{json}");
            assert!(parse_value(&literal).is_ok(), "{literal}");
        }
    }

    #[test]
    fn a_row_is_an_insert_one_of_its_fields() {
        let start = insert_start(&TableRef::new(Some("shop".to_owned()), "orders"));
        let document = insert_document(&[
            ("_id".to_owned(), "1".to_owned()),
            ("a b".to_owned(), "\"x\"".to_owned()),
        ]);

        assert_eq!(
            format!("{start}{document});"),
            r#"db.getSiblingDB("shop").getCollection("orders").insertOne({"_id": 1, "a b": "x"});"#
        );
    }
}
