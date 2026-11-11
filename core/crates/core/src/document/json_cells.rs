use std::borrow::Cow;

use crate::column::{ColumnInfo, ColumnKind, ColumnType};
use crate::query_result::QueryResult;
use crate::sql_syntax::mongo::{ShellValue, parse_value};
use crate::value::{JsonText, SqlDecimal, Temporal, Value};

/// Longer than any numeric wrapper: a longer cell is a document, read
/// without parsing it.
const WRAPPER_LIMIT: usize = 128;

/// A page's cells in a column the grid edits as JSON, written as
/// extended JSON. A field whose documents hold values of several types is
/// such a column: a string there reads `"abc"` and an id `{"$oid": ...}`,
/// so the editor opens on text that saves back as the same type.
pub(crate) fn json_cells(mut result: QueryResult, columns: &[ColumnInfo]) -> QueryResult {
    let json_columns: Vec<usize> = columns
        .iter()
        .enumerate()
        .filter(|(_, column)| matches!(column.column_type.kind, ColumnKind::Json { .. }))
        .map(|(index, _)| index)
        .collect();
    if json_columns.is_empty() {
        return result;
    }
    for row in &mut result.rows {
        for &index in &json_columns {
            if let Some(cell) = row.get_mut(index) {
                let value = std::mem::replace(cell, Value::Null);
                *cell = as_json(value);
            }
        }
    }
    result
}

/// A cell of a `NUMBER_TYPE` column that holds one number, as the
/// number: a bare JSON number, or one Extended JSON wrapper of its digits,
/// `{"$numberLong": "7"}`. A row export writes it as a number column's
/// cell, which a sheet sums. Any other value, and any other column's,
/// comes back as it is.
pub(crate) fn json_number<'a>(value: &'a Value, column: &ColumnType) -> Cow<'a, Value> {
    let number = match value {
        Value::Json(json) if holds_numbers(column) => numeric_json(json.as_str().trim()),
        _ => None,
    };
    number.map_or(Cow::Borrowed(value), Cow::Owned)
}

/// Whether the column is the JSON column of a field of numbers.
pub(crate) fn holds_numbers(column: &ColumnType) -> bool {
    column.name == super::NUMBER_TYPE && matches!(column.kind, ColumnKind::Json { .. })
}

fn numeric_json(text: &str) -> Option<Value> {
    match text.as_bytes().first()? {
        b'-' | b'0'..=b'9' => plain_number(text),
        b'{' if text.len() <= WRAPPER_LIMIT => wrapped_number(text),
        _ => None,
    }
}

/// A number's digits as they read. A double, which relaxed Extended JSON
/// writes in its shortest round-trip form, stays a double, so a sheet keeps
/// it a number; other digits stay exact as a decimal.
fn plain_number(text: &str) -> Option<Value> {
    if let Ok(integer) = text.parse() {
        return Some(Value::Int(integer));
    }
    let double = text.parse::<f64>().ok().filter(|number| number.is_finite());
    match double {
        Some(number) if text.contains(['e', 'E']) || format!("{number:?}") == text => Some(Value::Float64(number)),
        _ => text.parse().ok().map(Value::Decimal),
    }
}

fn wrapped_number(text: &str) -> Option<Value> {
    let value = parse_value(text).ok()?;
    let [(key, ShellValue::String(digits))] = value.as_object()? else {
        return None;
    };
    match key.as_str() {
        "$numberInt" => digits.parse::<i32>().ok().map(|number| Value::Int(number.into())),
        "$numberLong" => digits.parse().ok().map(Value::Int),
        "$numberDouble" => match digits.as_str() {
            "NaN" | "Infinity" | "-Infinity" => digits.parse().ok().map(Value::Float64),
            _ => plain_number(digits),
        },
        "$numberDecimal" => digits.parse::<SqlDecimal>().ok().map(Value::Decimal),
        _ => None,
    }
}

fn as_json(value: Value) -> Value {
    let text = match &value {
        Value::Null | Value::Json(_) | Value::Undecodable(_) => return value,
        Value::Text(text) => quoted(text),
        Value::Bool(flag) => flag.to_string(),
        Value::Int(number) => number.to_string(),
        Value::UInt(number) => number.to_string(),
        Value::WideInt(number) => wrapped("$numberDecimal", &quoted(&number.to_string())),
        Value::Float64(number) => double(*number),
        Value::Float32(number) => double(f64::from(*number)),
        Value::Decimal(number) => wrapped("$numberDecimal", &quoted(&number.to_string())),
        Value::Uuid(uuid) => wrapped("$uuid", &quoted(&uuid.to_string())),
        Value::Bytes(bytes) => wrapped(
            "$binary",
            &format!("{{\"base64\": {}, \"subType\": \"00\"}}", quoted(&base64(bytes))),
        ),
        Value::TimestampTz(Temporal::Finite(stamp)) => {
            let millis = stamp.to_datetime().timestamp_millis();
            wrapped("$date", &wrapped("$numberLong", &quoted(&millis.to_string())))
        }
        Value::Other(other) if other.type_name == "objectId" => wrapped("$oid", &quoted(&other.text)),
        _ => return value,
    };
    JsonText::parse(text).map_or(value, Value::Json)
}

fn quoted(text: &str) -> String {
    serde_json::Value::String(text.to_owned()).to_string()
}

fn wrapped(key: &str, inner: &str) -> String {
    format!("{{{}: {inner}}}", quoted(key))
}

/// A double keeps a fraction or an exponent, so it reads back as one.
fn double(number: f64) -> String {
    if !number.is_finite() {
        let name = match number {
            number if number.is_nan() => "NaN",
            number if number < 0.0 => "-Infinity",
            _ => "Infinity",
        };
        return wrapped("$numberDouble", &quoted(name));
    }
    let text = format!("{number:?}");
    match text.contains(['.', 'e', 'E']) {
        true => text,
        false => format!("{text}.0"),
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(super) fn base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (index, byte)| acc | (u32::from(*byte) << (16 - 8 * index)));
        for index in 0..4 {
            if index <= chunk.len() {
                let sextet = (triple >> (18 - 6 * index)) & 0x3f;
                out.push(char::from(ALPHABET[sextet as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The bytes of standard base64, `None` for text that is not.
pub(super) fn base64_bytes(text: &str) -> Option<Vec<u8>> {
    let mut bytes = Vec::with_capacity(text.len() / 4 * 3);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for digit in text.trim_end_matches('=').bytes() {
        let sextet = ALPHABET.iter().position(|&letter| letter == digit)?;
        buffer = ((buffer << 6) | sextet as u32) & 0xffff;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
        }
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use crate::column::ResultColumn;
    use crate::column::{ColumnDefault, ColumnType, ReadForm, TextLength};
    use crate::value::OtherValue;

    use super::*;

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: "mixed".to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_number_columns_cell_of_one_number_is_that_number_and_any_other_stays() {
        let numbers_column = column("n", ColumnKind::Json { binary: false }).column_type;
        let numbers_column = ColumnType {
            name: crate::document::NUMBER_TYPE.to_owned(),
            ..numbers_column
        };
        let json = |text: &str| Value::Json(JsonText::parse(text.to_owned()).unwrap());
        let decimal = |text: &str| Value::Decimal(text.parse().unwrap());
        let numbers = [
            ("7", Value::Int(7)),
            ("-7", Value::Int(-7)),
            ("19.90", decimal("19.90")),
            ("-0.1", Value::Float64(-0.1)),
            ("9.99", Value::Float64(9.99)),
            ("0.30000000000000004", Value::Float64(0.300_000_000_000_000_04)),
            ("1e3", Value::Float64(1000.0)),
            ("2.5E-7", Value::Float64(2.5e-7)),
            ("123456789012345678901234", decimal("123456789012345678901234")),
            (r#"{"$numberInt": "7"}"#, Value::Int(7)),
            (r#"{"$numberLong": "3000000000"}"#, Value::Int(3_000_000_000)),
            (r#" { "$numberDouble": "1.50" } "#, decimal("1.50")),
            (r#"{"$numberDouble": "1e300"}"#, Value::Float64(1e300)),
            (r#"{"$numberDouble": "-Infinity"}"#, Value::Float64(f64::NEG_INFINITY)),
            (r#"{"$numberDecimal": "9.990"}"#, decimal("9.990")),
        ];
        for (text, number) in numbers {
            assert_eq!(json_number(&json(text), &numbers_column).into_owned(), number, "{text}");
        }
        assert!(matches!(
            json_number(&json(r#"{"$numberDouble": "NaN"}"#), &numbers_column).into_owned(),
            Value::Float64(number) if number.is_nan()
        ));

        for kept in [
            json(r#""7""#),
            json("null"),
            json("[1]"),
            json(r#"{"$numberLong": 7}"#),
            json(r#"{"$numberLong": "x"}"#),
            json(r#"{"$numberInt": "3000000000"}"#),
            json(r#"{"$numberLong": "1", "a": 1}"#),
            json(r#"{"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}"#),
            Value::Text("7".to_owned()),
        ] {
            assert!(
                matches!(json_number(&kept, &numbers_column), Cow::Borrowed(_)),
                "{kept:?}"
            );
        }
        let jsonb = ColumnType {
            name: "jsonb".to_owned(),
            ..numbers_column.clone()
        };
        let mixed = column("m", ColumnKind::Json { binary: false }).column_type;
        let text_named_number = ColumnType {
            kind: ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            ..numbers_column
        };
        for other in [jsonb, mixed, text_named_number] {
            for cell in [json("19.90"), json(r#"{"$numberLong": "7"}"#)] {
                assert!(matches!(json_number(&cell, &other), Cow::Borrowed(_)), "{other:?}");
            }
        }
        assert_eq!(base64_bytes("aGkh"), Some(b"hi!".to_vec()));
        assert_eq!(base64_bytes("aGk="), Some(b"hi".to_vec()));
        assert_eq!(base64_bytes("a*"), None);
    }

    #[test]
    fn a_json_column_shows_each_value_as_json_and_the_others_stay() {
        let columns = [
            column("mixed", ColumnKind::Json { binary: false }),
            column(
                "text",
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
            ),
        ];
        let id = Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
        }));
        let rows = vec![
            vec![Value::Text("a\"b".to_owned()), Value::Text("plain".to_owned())],
            vec![Value::Int(5), Value::Null],
            vec![Value::Float64(2.0), Value::Null],
            vec![id, Value::Null],
            vec![Value::Bytes(b"hi!".to_vec()), Value::Null],
            vec![Value::Null, Value::Null],
        ];
        let result = QueryResult::new(
            vec![
                ResultColumn::new("mixed", ColumnType::unknown()),
                ResultColumn::new("text", ColumnType::unknown()),
            ],
            rows,
        );

        let shaped = json_cells(result, &columns);

        let texts: Vec<String> = shaped
            .rows
            .iter()
            .map(|row| match &row[0] {
                Value::Json(json) => json.as_str().to_owned(),
                other => format!("{other:?}"),
            })
            .collect();
        assert_eq!(
            texts,
            [
                r#""a\"b""#,
                "5",
                "2.0",
                r#"{"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}"#,
                r#"{"$binary": {"base64": "aGkh", "subType": "00"}}"#,
                "Null",
            ]
        );
        assert_eq!(shaped.rows[0][1], Value::Text("plain".to_owned()));
        assert_eq!(base64(b"hi"), "aGk=");
        assert_eq!(base64(b"h"), "aA==");
    }
}
