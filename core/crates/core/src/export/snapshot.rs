use serde::ser::{Serialize, SerializeSeq, Serializer};
use serde_json::value::RawValue;

use crate::column::{ColumnKind, ResultColumn};
use crate::value::Value;

use super::json::JsonCell;
use super::value_text::element_kind;

// A result as a share link carries it. Cells are raw JSON tokens, so a big number keeps every digit and a JSON
// column keeps its key order, which serde_json::Value would lose.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub columns: Vec<SnapshotColumn>,
    pub rows: Vec<Vec<Box<RawValue>>>,
    // Every row of the result, the ones left out included.
    pub row_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotColumn {
    pub name: String,
    pub type_name: String,
}

impl Snapshot {
    pub fn truncated(&self) -> bool {
        self.row_count > self.rows.len() as u64
    }
}

// Takes at most `max_rows` rows; `row_count` is the result's true total, which a caller that holds every row gives
// as their count.
pub fn build_snapshot<R: AsRef<[Value]>>(
    columns: &[ResultColumn],
    rows: impl IntoIterator<Item = R>,
    row_count: u64,
    max_rows: usize,
) -> Snapshot {
    let rows: Vec<Vec<Box<RawValue>>> = rows
        .into_iter()
        .take(max_rows)
        .map(|row| snapshot_row(columns, row.as_ref()))
        .collect();
    Snapshot {
        columns: columns
            .iter()
            .map(|column| SnapshotColumn {
                name: column.name.clone(),
                type_name: column.column_type.name.clone(),
            })
            .collect(),
        row_count: row_count.max(rows.len() as u64),
        rows,
    }
}

// One cell per column: a short row's missing cells are null, and a cell past the last column has nowhere to go.
fn snapshot_row(columns: &[ResultColumn], row: &[Value]) -> Vec<Box<RawValue>> {
    columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            let value = row.get(index).unwrap_or(&Value::Null);
            let value = crate::document::json_number(value, &column.column_type);
            let cell = SnapshotCell {
                value: &value,
                kind: &column.column_type.kind,
            };
            serde_json::value::to_raw_value(&cell).unwrap_or_else(|_| RawValue::NULL.to_owned())
        })
        .collect()
}

// The export's JSON cell, except that bytes name their size: a viewer has no use for hex it cannot show.
struct SnapshotCell<'a> {
    value: &'a Value,
    kind: &'a ColumnKind,
}

impl Serialize for SnapshotCell<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.value {
            Value::Bytes(bytes) => serializer.serialize_str(&format!("(binary, {} bytes)", bytes.len())),
            Value::Array(values) => {
                let element = element_kind(self.kind);
                let mut seq = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    seq.serialize_element(&SnapshotCell { value, kind: element })?;
                }
                seq.end()
            }
            value => JsonCell { value, kind: self.kind }.serialize(serializer),
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnKind, IntegerKind, IntegerWidth, TemporalZone, TextLength};
    use crate::value::{JsonText, Temporal, UndecodableReason, UndecodedValue};

    use super::super::test_columns::{cols, typed};
    use super::*;

    fn texts(snapshot: &Snapshot) -> Vec<Vec<&str>> {
        snapshot
            .rows
            .iter()
            .map(|row| row.iter().map(|cell| cell.get()).collect())
            .collect()
    }

    #[test]
    fn rows_past_the_cap_are_left_out_and_counted() {
        let columns = cols(&["n"]);
        let rows: Vec<Vec<Value>> = (0..5).map(|row| vec![Value::Int(row)]).collect();

        let snapshot = build_snapshot(&columns, &rows, rows.len() as u64, 3);

        assert_eq!(texts(&snapshot), [["0"], ["1"], ["2"]]);
        assert_eq!(snapshot.row_count, 5);
        assert!(snapshot.truncated());
    }

    #[test]
    fn a_result_within_the_cap_is_whole() {
        let columns = cols(&["n"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(2)]];

        let snapshot = build_snapshot(&columns, &rows, 2, 1_000);

        assert_eq!(snapshot.rows.len(), 2);
        assert_eq!(snapshot.row_count, 2);
        assert!(!snapshot.truncated());
    }

    #[test]
    fn a_count_below_the_rows_taken_is_raised_to_them() {
        let columns = cols(&["n"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(2)]];

        let snapshot = build_snapshot(&columns, &rows, 0, 10);

        assert_eq!(snapshot.row_count, 2);
    }

    #[test]
    fn columns_carry_their_name_and_type() {
        let columns = vec![
            typed(
                "id",
                "bigint",
                ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W64,
                    signed: true,
                }),
            ),
            typed("body", "text", ColumnKind::Other),
        ];

        let snapshot = build_snapshot(&columns, std::iter::empty::<Vec<Value>>(), 0, 10);

        assert_eq!(
            snapshot.columns,
            [
                SnapshotColumn {
                    name: "id".to_owned(),
                    type_name: "bigint".to_owned()
                },
                SnapshotColumn {
                    name: "body".to_owned(),
                    type_name: "text".to_owned()
                }
            ]
        );
    }

    #[test]
    fn big_numbers_and_decimals_keep_every_digit() {
        let columns = vec![
            typed(
                "u",
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
        let rows = vec![vec![
            Value::UInt(u64::MAX),
            Value::Decimal("12345678901234567890.12345678901234567890".parse().expect("a decimal")),
        ]];

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        assert_eq!(
            texts(&snapshot),
            [["18446744073709551615", "12345678901234567890.12345678901234567890"]]
        );
    }

    #[test]
    fn a_json_column_goes_in_as_its_document_with_its_key_order() {
        let columns = vec![typed("payload", "jsonb", ColumnKind::Json { binary: true })];
        let rows = vec![vec![Value::Json(
            JsonText::parse(r#"{"b": 1, "a": [1, 2]}"#.to_owned()).expect("JSON"),
        )]];

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        assert_eq!(texts(&snapshot), [[r#"{"b": 1, "a": [1, 2]}"#]]);
    }

    #[test]
    fn bytes_name_their_size_inside_arrays_too() {
        let columns = vec![
            typed(
                "blob",
                "bytea",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
            typed(
                "blobs",
                "bytea[]",
                ColumnKind::Array {
                    element: Box::new(ColumnKind::Bytes {
                        length: TextLength::Unbounded,
                    }),
                },
            ),
        ];
        let rows = vec![vec![
            Value::Bytes(vec![0xca, 0xfe, 0x00]),
            Value::Array(vec![Value::Bytes(vec![1]), Value::Null]),
        ]];

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        assert_eq!(
            texts(&snapshot),
            [[r#""(binary, 3 bytes)""#, r#"["(binary, 1 bytes)",null]"#]]
        );
    }

    #[test]
    fn timestamps_are_iso_and_an_unreadable_value_is_null() {
        let columns = vec![
            typed(
                "at",
                "timestamp(3)",
                ColumnKind::Timestamp {
                    fractional_digits: Some(3),
                    zone: TemporalZone::Naive,
                },
            ),
            typed("odd", "geometry", ColumnKind::Other),
        ];
        let stamp = chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
            .expect("a date")
            .and_hms_milli_opt(12, 0, 0, 500)
            .expect("a time");
        let rows = vec![vec![
            Value::Timestamp(Temporal::Finite(stamp)),
            Value::Undecodable(Box::new(UndecodedValue {
                type_name: "geometry".to_owned(),
                reason: UndecodableReason::UnsupportedType,
            })),
        ]];

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        assert_eq!(texts(&snapshot), [[r#""2024-06-15T12:00:00.500""#, "null"]]);
    }

    #[test]
    fn a_short_row_fills_with_null_and_a_long_one_is_cut_to_the_columns() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(1), Value::Int(2), Value::Int(3)]];

        let snapshot = build_snapshot(&columns, &rows, 2, 10);

        assert_eq!(texts(&snapshot), [["1", "null"], ["1", "2"]]);
    }

    #[test]
    fn a_number_field_s_json_goes_in_as_the_number() {
        let (columns, rows) = super::super::test_columns::mixed_json();

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        let row = &texts(&snapshot)[0];
        assert_eq!(row[0], "3000000000");
        assert_eq!(row[1], "19.90");
    }

    #[test]
    fn every_cell_is_json_a_reader_parses() {
        let columns = cols(&["s", "f"]);
        let rows = vec![vec![
            Value::Text("a \"quoted\"\nline".to_owned()),
            Value::Float64(f64::NAN),
        ]];

        let snapshot = build_snapshot(&columns, &rows, 1, 10);

        let parsed: Vec<serde_json::Value> = snapshot.rows[0]
            .iter()
            .map(|cell| serde_json::from_str(cell.get()).expect("JSON"))
            .collect();
        assert_eq!(
            parsed,
            [serde_json::json!("a \"quoted\"\nline"), serde_json::json!("NaN")]
        );
    }
}
