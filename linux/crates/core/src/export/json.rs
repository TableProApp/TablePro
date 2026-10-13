use serde::ser::{Serialize, SerializeMap, SerializeSeq, Serializer};
use serde_json::value::RawValue;

use crate::column::{ColumnKind, ResultColumn};
use crate::value::Value;

use super::column_type;
use super::json_field_names::json_field_names;
use super::value_text::{element_kind, kind_text};

/// One row as a JSON object, keyed by the names the columns resolve to.
struct JsonRow<'a> {
    names: &'a [String],
    columns: &'a [ResultColumn],
    row: &'a [Value],
}

impl Serialize for JsonRow<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.names.len()))?;
        for (index, name) in self.names.iter().enumerate() {
            match self.row.get(index) {
                Some(value) => map.serialize_entry(
                    name,
                    &JsonCell {
                        value,
                        kind: &column_type(self.columns, index).kind,
                    },
                )?,
                // A row shorter than its header: the cell is missing,
                // which is not the same as a NULL the row holds.
                None => map.serialize_entry(name, &Option::<()>::None)?,
            }
        }
        map.end()
    }
}

/// One cell.
///
/// Numbers go out as the digits the server sent rather than through a
/// float: `18446744073709551615` and `1.0000000000` both lose their
/// value on the way through one.
struct JsonCell<'a> {
    value: &'a Value,
    kind: &'a ColumnKind,
}

impl Serialize for JsonCell<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.value {
            Value::Null | Value::Undecodable(_) => serializer.serialize_none(),
            Value::Bool(flag) => serializer.serialize_bool(*flag),
            Value::Int(number) => serializer.serialize_i64(*number),
            Value::UInt(number) => serializer.serialize_u64(*number),
            Value::WideInt(number) => number_token(serializer, &number.to_string()),
            // Each width at its own shortest digits: a `real` widened
            // to a double prints `0.10000000149011612` for 0.1.
            Value::Float32(number) if number.is_finite() => serializer.serialize_f32(*number),
            Value::Float64(number) if number.is_finite() => serializer.serialize_f64(*number),
            Value::Decimal(decimal) if decimal.is_finite() => {
                number_token(serializer, &kind_text(self.value, self.kind).unwrap_or_default())
            }
            // A JSON column already holds a document, so it goes in as
            // one rather than as a string of one.
            Value::Json(json) => match RawValue::from_string(json.as_str().to_owned()) {
                Ok(raw) => raw.serialize(serializer),
                Err(_) => serializer.serialize_str(json.as_str()),
            },
            Value::Array(values) => {
                let element = element_kind(self.kind);
                let mut seq = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    seq.serialize_element(&JsonCell { value, kind: element })?;
                }
                seq.end()
            }
            Value::Timestamp(_) | Value::TimestampTz(_) => {
                let text = kind_text(self.value, self.kind).unwrap_or_default();
                serializer.serialize_str(&text.replacen(' ', "T", 1))
            }
            // JSON has no NaN or Infinity, so a non-finite number goes
            // out as its name rather than as a null that reads like a
            // missing value.
            other => match kind_text(other, self.kind) {
                Some(text) => serializer.serialize_str(&text),
                None => serializer.serialize_none(),
            },
        }
    }
}

/// A number written exactly as its digits read, which no JSON number
/// type would hold.
fn number_token<S: Serializer>(serializer: S, digits: &str) -> Result<S::Ok, S::Error> {
    match RawValue::from_string(digits.to_owned()) {
        Ok(raw) => raw.serialize(serializer),
        // Not a number JSON accepts, so it goes out as text rather
        // than as a token that would not parse back.
        Err(_) => serializer.serialize_str(digits),
    }
}

/// One row as a document a person reads, which is the only place a
/// single row is rendered on its own.
pub fn row_to_json(columns: &[ResultColumn], row: &[Value]) -> String {
    let names = json_field_names(columns);
    let value = JsonRow {
        names: &names,
        columns,
        row,
    };
    serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_owned())
}

pub fn render_json(columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
    let names = json_field_names(columns);
    let values: Vec<JsonRow<'_>> = rows
        .iter()
        .map(|row| JsonRow {
            names: &names,
            columns,
            row,
        })
        .collect();
    serde_json::to_string_pretty(&values).unwrap_or_else(|_| "[]".to_owned())
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnKind, IntegerKind, IntegerWidth, TemporalZone};

    use super::super::test_columns::{cols, typed};
    use super::*;

    fn parsed(columns: &[ResultColumn], row: &[Value]) -> serde_json::Value {
        serde_json::from_str(&row_to_json(columns, row)).expect("the row is JSON")
    }

    #[test]
    fn json_number_vs_string_handling() {
        let columns = cols(&["i", "f", "d", "s"]);
        let row = vec![
            Value::Int(5),
            Value::Float64(1.5),
            Value::Decimal("9.99".parse().expect("a decimal")),
            Value::Text("hi".into()),
        ];

        let json = parsed(&columns, &row);

        assert_eq!(json["i"], serde_json::json!(5));
        assert_eq!(json["f"], serde_json::json!(1.5));
        assert_eq!(json["d"], serde_json::json!(9.99));
        assert_eq!(json["s"], serde_json::json!("hi"));
    }

    #[test]
    fn json_emits_raw_number_tokens_for_u64_max_and_decimal_40_20() {
        let columns = vec![
            typed(
                "bigint unsigned",
                "bigint unsigned",
                ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W64,
                    signed: false,
                }),
            ),
            typed(
                "amount",
                "numeric(40,20)",
                ColumnKind::Decimal {
                    precision: Some(40),
                    scale: Some(20),
                },
            ),
        ];
        let row = vec![
            Value::UInt(u64::MAX),
            Value::Decimal("12345678901234567890.12345678901234567890".parse().expect("a decimal")),
        ];

        let text = row_to_json(&columns, &row);

        assert!(text.contains("18446744073709551615"), "{text}");
        assert!(
            text.contains("12345678901234567890.12345678901234567890"),
            "a decimal past a double's precision was rounded: {text}"
        );
        assert!(
            !text.contains("\"18446744073709551615\""),
            "the number went out as text"
        );
    }

    #[test]
    fn a_decimal_fills_out_its_column_scale() {
        let columns = vec![typed(
            "amount",
            "numeric(38,10)",
            ColumnKind::Decimal {
                precision: Some(38),
                scale: Some(10),
            },
        )];
        let row = vec![Value::Decimal("1".parse().expect("a decimal"))];

        let text = row_to_json(&columns, &row);

        assert!(text.contains("1.0000000000"), "{text}");
    }

    #[test]
    fn json_embeds_json_column_verbatim() {
        let document = r#"{"b": 1, "a": [1, 2]}"#;
        let columns = vec![typed("payload", "jsonb", ColumnKind::Json { binary: true })];
        let row = vec![Value::Json(
            crate::value::JsonText::parse(document.to_owned()).expect("valid json"),
        )];

        let text = row_to_json(&columns, &row);

        assert!(
            text.contains(&format!("\"payload\": {document}")),
            "the document was rewritten or quoted: {text}"
        );
    }

    #[test]
    fn json_non_finite_is_string() {
        let columns = cols(&["double", "real", "nan", "negative"]);
        let row = vec![
            Value::Float64(f64::INFINITY),
            Value::Float32(f32::NAN),
            Value::Decimal("NaN".parse().expect("a decimal")),
            Value::Decimal("-Infinity".parse().expect("a decimal")),
        ];

        let json = parsed(&columns, &row);

        assert_eq!(json["double"], serde_json::json!("Infinity"));
        assert_eq!(json["real"], serde_json::json!("NaN"));
        assert_eq!(json["nan"], serde_json::json!("NaN"));
        assert_eq!(json["negative"], serde_json::json!("-Infinity"));
    }

    #[test]
    fn a_real_goes_out_at_its_own_digits() {
        let columns = cols(&["r"]);
        let row = vec![Value::Float32(0.1)];

        let text = row_to_json(&columns, &row);

        assert!(
            text.contains("\"r\": 0.1\n"),
            "the real was widened to a double: {text}"
        );
    }

    #[test]
    fn array_items_go_out_at_their_element_scale() {
        let columns = vec![typed(
            "amounts",
            "numeric(5,2)[]",
            ColumnKind::Array {
                element: Box::new(ColumnKind::Decimal {
                    precision: Some(5),
                    scale: Some(2),
                }),
            },
        )];
        let row = vec![Value::Array(vec![
            Value::Decimal("1.5".parse().expect("a decimal")),
            Value::Null,
        ])];

        let text = row_to_json(&columns, &row);

        assert!(text.contains("1.50,"), "the item lost its column's scale: {text}");
        assert_eq!(parsed(&columns, &row)["amounts"], serde_json::json!([1.5, null]));
    }

    #[test]
    fn a_timestamp_goes_out_in_the_form_readers_expect() {
        let columns = vec![typed(
            "at",
            "timestamp(3)",
            ColumnKind::Timestamp {
                fractional_digits: Some(3),
                zone: TemporalZone::Naive,
            },
        )];
        let stamp = chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
            .expect("a date")
            .and_hms_milli_opt(12, 0, 0, 500)
            .expect("a time");
        let row = vec![Value::Timestamp(crate::value::Temporal::Finite(stamp))];

        let json = parsed(&columns, &row);

        assert_eq!(json["at"], serde_json::json!("2024-06-15T12:00:00.500"));
    }

    #[test]
    fn json_missing_cell_is_null() {
        let columns = cols(&["a", "b"]);
        let row = vec![Value::Int(1)];

        let json = parsed(&columns, &row);

        assert_eq!(json["b"], serde_json::Value::Null);
    }

    #[test]
    fn json_keeps_every_column_when_names_repeat() {
        let columns = cols(&["id", "name", "id"]);
        let row = vec![Value::Int(1), Value::Text("a".into()), Value::Int(2)];

        let json = parsed(&columns, &row);

        assert_eq!(json["id"], serde_json::json!(1));
        assert_eq!(json["id_2"], serde_json::json!(2));
    }

    #[test]
    fn render_json_empty_rows_is_empty_array() {
        let columns = cols(&["a"]);

        assert_eq!(render_json(&columns, &[]), "[]");
    }
}
