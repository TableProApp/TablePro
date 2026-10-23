use crate::column::{ColumnInfo, ColumnKind};
use crate::query_result::QueryResult;
use crate::value::{JsonText, Temporal, Value};

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

pub(super) fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
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
            default: ColumnDefault::None,
            comment: None,
        }
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
