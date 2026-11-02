use crate::column::ColumnType;
use crate::dialect::LiteralError;
use crate::meta::TableRef;
use crate::sql_syntax::mongo::ShellValue;
use crate::value::{Temporal, Value};

use super::document_read::collection;

/// A value as shell text that reads back as the same value and type: a
/// copied document and an exported row can be run again as they are.
pub fn shell_literal(value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
    let quoted = |text: &str| ShellValue::string(text).to_string();
    Ok(match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Int(number) => match (column.name.as_str(), i32::try_from(*number)) {
            ("long", _) | (_, Err(_)) => format!("NumberLong({})", quoted(&number.to_string())),
            (_, Ok(small)) => small.to_string(),
        },
        Value::UInt(number) => match i64::try_from(*number) {
            Ok(number) => format!("NumberLong({})", quoted(&number.to_string())),
            Err(_) => format!("NumberDecimal({})", quoted(&number.to_string())),
        },
        Value::WideInt(number) => format!("NumberDecimal({})", quoted(&number.to_string())),
        Value::Decimal(number) => format!("NumberDecimal({})", quoted(&number.to_string())),
        Value::Float64(number) => double(*number),
        Value::Float32(number) => double(f64::from(*number)),
        Value::Text(text) => quoted(text),
        Value::Json(json) => json.as_str().to_owned(),
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

/// A double keeps a fraction or an exponent, so it reads back as one.
fn double(number: f64) -> String {
    if number.is_nan() {
        return "NaN".to_owned();
    }
    if number.is_infinite() {
        return if number < 0.0 { "-Infinity" } else { "Infinity" }.to_owned();
    }
    let text = format!("{number:?}");
    match text.contains(['.', 'e', 'E']) {
        true => text,
        false => format!("{text}.0"),
    }
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
            (Value::Float64(2.0), "double", "2.0"),
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
                r#"{"a": {"$numberLong": "1"}}"#,
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
