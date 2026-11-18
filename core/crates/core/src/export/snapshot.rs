use serde::ser::{Serialize, SerializeSeq, Serializer};
use serde_json::value::RawValue;
use thiserror::Error;

use crate::Truncation;
use crate::column::{ColumnKind, ResultColumn};
use crate::masking::MaskingStyle;
use crate::value::Value;

use super::json::JsonCell;
use super::value_text::element_kind;

// A result as a share link carries it. Cells are raw JSON tokens, so a big number keeps every digit and a JSON
// column keeps its key order, which serde_json::Value would lose.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub columns: Vec<SnapshotColumn>,
    pub rows: Vec<Vec<Box<RawValue>>>,
    // Every row of the result, the ones left out included; None when it was cut and nobody counted it.
    pub row_count: Option<u64>,
    // Rows exist beyond those here, how many unknown.
    pub more_rows: bool,
}

// What a result knows of its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResultExtent {
    // The rows the result holds.
    pub held: u64,
    // Every row of the result when something counted them: the server, or a count of a table view.
    pub total: Option<u64>,
    // Rows may follow those held: a row or byte limit, one page of a table, or a run that ended first.
    pub cut: bool,
}

impl ResultExtent {
    pub fn complete(held: u64) -> Self {
        Self {
            held,
            total: None,
            cut: false,
        }
    }

    // As the result's `ResultEvent::ResultSetFinished` reports it.
    pub fn finished(held: u64, total_rows: Option<u64>, truncation: Truncation) -> Self {
        Self {
            held,
            total: total_rows,
            cut: truncation != Truncation::Complete,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotColumn {
    pub name: String,
    pub type_name: String,
    // How the app masked the column's values before they left it; the viewer marks the column.
    pub masked: Option<MaskingStyle>,
}

impl Snapshot {
    pub fn truncated(&self) -> bool {
        self.more_rows || self.row_count.is_some_and(|count| count > self.rows.len() as u64)
    }
}

// What a snapshot body may weigh, as the macOS app counts it (ShareSnapshotBuilder): under the server's 5 MiB, so a
// size it counts differently never refuses a share the app offered.
pub const MAX_SNAPSHOT_BODY_BYTES: usize = 4_500_000;
pub const MAX_SNAPSHOT_CELL_BYTES: usize = 256 * 1_024;

// A share that cannot go out even cut: the server refuses a cell this big, a body with no row and a body with no
// column.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SnapshotRefusal {
    #[error("a value in column {column} is over 256 KiB")]
    Cell { column: String },
    #[error("the first row alone is over the share's 4.5 MB")]
    FirstRow,
    #[error("every column was removed")]
    NoColumns,
}

impl SnapshotRefusal {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Cell { .. } | Self::FirstRow => "export.snapshot_too_large",
            Self::NoColumns => "export.snapshot_no_columns",
        }
    }
}

// Takes at most `max_rows` rows, and stops before the row that would take the body past `MAX_SNAPSHOT_BODY_BYTES`; the
// row count stays the result's, so the server marks the share cut. A result cut with no count says only that more rows
// exist, so a viewer never reads the rows held as the whole result.
pub fn build_snapshot<R: AsRef<[Value]>>(
    columns: &[ResultColumn],
    rows: impl IntoIterator<Item = R>,
    extent: ResultExtent,
    max_rows: usize,
) -> Result<Snapshot, SnapshotRefusal> {
    if columns.is_empty() {
        return Err(SnapshotRefusal::NoColumns);
    }
    let mut budget = Budget::new(columns);
    let mut kept: Vec<Vec<Box<RawValue>>> = Vec::new();
    for row in rows.into_iter().take(max_rows) {
        let (cells, bytes) = sized_row(columns, row.as_ref())?;
        if !budget.take(bytes, kept.is_empty())? {
            break;
        }
        kept.push(cells);
    }
    let at_least = extent.held.max(kept.len() as u64);
    let (row_count, more_rows) = match (extent.total, extent.cut) {
        (Some(total), _) => (Some(total.max(at_least)), false),
        (None, false) => (Some(at_least), false),
        (None, true) => (None, true),
    };
    Ok(Snapshot {
        columns: columns
            .iter()
            .map(|column| SnapshotColumn {
                name: column.name.clone(),
                type_name: column.column_type.name.clone(),
                masked: None,
            })
            .collect(),
        row_count,
        more_rows,
        rows: kept,
    })
}

// How many of `rows` a snapshot of `max_rows` keeps, by the same budget, for a preview or a summary that must read
// exactly the rows sent.
pub fn snapshot_row_count<R: AsRef<[Value]>>(
    columns: &[ResultColumn],
    rows: impl IntoIterator<Item = R>,
    max_rows: usize,
) -> Result<usize, SnapshotRefusal> {
    let mut fit = SnapshotFit::new(columns)?;
    let mut kept = 0;
    for row in rows.into_iter().take(max_rows) {
        if !fit.take(row.as_ref())? {
            break;
        }
        kept += 1;
    }
    Ok(kept)
}

// The snapshot's cut a row at a time, for a reader that holds no rows: true while a row fits the body, false for the
// first that does not, and the refusal `build_snapshot` would give.
pub struct SnapshotFit<'c> {
    columns: &'c [ResultColumn],
    budget: Budget,
    kept: usize,
}

impl<'c> SnapshotFit<'c> {
    pub fn new(columns: &'c [ResultColumn]) -> Result<Self, SnapshotRefusal> {
        if columns.is_empty() {
            return Err(SnapshotRefusal::NoColumns);
        }
        Ok(Self {
            columns,
            budget: Budget::new(columns),
            kept: 0,
        })
    }

    pub fn take(&mut self, row: &[Value]) -> Result<bool, SnapshotRefusal> {
        let (_, bytes) = sized_row(self.columns, row)?;
        let fits = self.budget.take(bytes, self.kept == 0)?;
        self.kept += usize::from(fits);
        Ok(fits)
    }
}

// The body as the macOS app weighs it: braces and each column's quoted name plus 24, then each row's brackets, commas
// and closing comma.
struct Budget {
    spent: usize,
}

impl Budget {
    fn new(columns: &[ResultColumn]) -> Self {
        Self {
            spent: 2 + columns
                .iter()
                .map(|column| quoted_bytes(&column.name) + 24)
                .sum::<usize>(),
        }
    }

    // False once the row would cross the budget; the first row not fitting refuses the share.
    fn take(&mut self, row: usize, first: bool) -> Result<bool, SnapshotRefusal> {
        if self.spent + row > MAX_SNAPSHOT_BODY_BYTES {
            return match first {
                true => Err(SnapshotRefusal::FirstRow),
                false => Ok(false),
            };
        }
        self.spent += row;
        Ok(true)
    }
}

fn sized_row(columns: &[ResultColumn], row: &[Value]) -> Result<(Vec<Box<RawValue>>, usize), SnapshotRefusal> {
    let mut bytes = 2 + columns.len().saturating_sub(1) + 1;
    let mut cells = Vec::with_capacity(columns.len());
    for (index, column) in columns.iter().enumerate() {
        let value = row.get(index).unwrap_or(&Value::Null);
        let value = crate::document::json_number(value, &column.column_type);
        let cell = SnapshotCell {
            value: &value,
            kind: &column.column_type.kind,
        };
        let token = serde_json::value::to_raw_value(&cell).unwrap_or_else(|_| RawValue::NULL.to_owned());
        let size = cell_bytes(&value, &column.column_type.kind, &token);
        if size > MAX_SNAPSHOT_CELL_BYTES {
            return Err(SnapshotRefusal::Cell {
                column: column.name.clone(),
            });
        }
        bytes += size;
        cells.push(token);
    }
    Ok((cells, bytes))
}

// A cell's JSON bytes as the macOS app counts them: a document and a number as written, a string with `<`, `>` and `&`
// escaped as six bytes each, an array element by element.
fn cell_bytes(value: &Value, kind: &ColumnKind, token: &RawValue) -> usize {
    match value {
        Value::Array(values) => {
            let element = element_kind(kind);
            2 + values.len().saturating_sub(1)
                + values
                    .iter()
                    .map(|value| {
                        let cell = SnapshotCell { value, kind: element };
                        serde_json::value::to_raw_value(&cell).map_or(4, |token| cell_bytes(value, element, &token))
                    })
                    .sum::<usize>()
        }
        Value::Json(_) => token.get().len(),
        _ => match token.get().starts_with('"') {
            true => serde_json::from_str::<String>(token.get()).map_or(token.get().len(), |text| quoted_bytes(&text)),
            false => token.get().len(),
        },
    }
}

fn quoted_bytes(text: &str) -> usize {
    2 + text
        .bytes()
        .map(|byte| match byte {
            b'"' | b'\\' | 0x08 | 0x0c | b'\n' | b'\r' | b'\t' => 2,
            0x00..=0x1f | b'<' | b'>' | b'&' => 6,
            _ => 1,
        })
        .sum::<usize>()
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

    fn snap<R: AsRef<[Value]>>(
        columns: &[ResultColumn],
        rows: impl IntoIterator<Item = R>,
        extent: ResultExtent,
        max_rows: usize,
    ) -> Snapshot {
        build_snapshot(columns, rows, extent, max_rows).expect("a snapshot")
    }

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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(rows.len() as u64), 3);

        assert_eq!(texts(&snapshot), [["0"], ["1"], ["2"]]);
        assert_eq!(snapshot.row_count, Some(5));
        assert!(snapshot.truncated());
    }

    #[test]
    fn a_result_within_the_cap_is_whole() {
        let columns = cols(&["n"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(2)]];

        let snapshot = snap(&columns, &rows, ResultExtent::complete(2), 1_000);

        assert_eq!(snapshot.rows.len(), 2);
        assert_eq!(snapshot.row_count, Some(2));
        assert!(!snapshot.truncated());
    }

    #[test]
    fn a_count_below_the_rows_taken_is_raised_to_them() {
        let columns = cols(&["n"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(2)]];

        let snapshot = snap(&columns, &rows, ResultExtent::complete(0), 10);

        assert_eq!(snapshot.row_count, Some(2));
    }

    #[test]
    fn a_cut_result_nobody_counted_says_only_that_more_rows_exist() {
        let columns = cols(&["n"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(2)]];
        let cut = |total, truncation| ResultExtent::finished(2, total, truncation);

        let uncounted = snap(&columns, &rows, cut(None, Truncation::ReadPastLimit), 10);
        let byte_limit = snap(&columns, &rows, cut(None, Truncation::ByteLimit), 10);
        let counted = snap(&columns, &rows, cut(Some(48_210), Truncation::ReadPastLimit), 10);

        assert_eq!((uncounted.row_count, uncounted.more_rows), (None, true));
        assert!(uncounted.truncated());
        assert_eq!((byte_limit.row_count, byte_limit.more_rows), (None, true));
        assert_eq!((counted.row_count, counted.more_rows), (Some(48_210), false));
        assert!(counted.truncated());
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

        let snapshot = snap(
            &columns,
            std::iter::empty::<Vec<Value>>(),
            ResultExtent::complete(0),
            10,
        );

        assert_eq!(
            snapshot.columns,
            [
                SnapshotColumn {
                    name: "id".to_owned(),
                    type_name: "bigint".to_owned(),
                    masked: None,
                },
                SnapshotColumn {
                    name: "body".to_owned(),
                    type_name: "text".to_owned(),
                    masked: None,
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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

        assert_eq!(texts(&snapshot), [[r#""2024-06-15T12:00:00.500""#, "null"]]);
    }

    #[test]
    fn a_short_row_fills_with_null_and_a_long_one_is_cut_to_the_columns() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1)], vec![Value::Int(1), Value::Int(2), Value::Int(3)]];

        let snapshot = snap(&columns, &rows, ResultExtent::complete(2), 10);

        assert_eq!(texts(&snapshot), [["1", "null"], ["1", "2"]]);
    }

    #[test]
    fn a_number_field_s_json_goes_in_as_the_number() {
        let (columns, rows) = super::super::test_columns::mixed_json();

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

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

        let snapshot = snap(&columns, &rows, ResultExtent::complete(1), 10);

        let parsed: Vec<serde_json::Value> = snapshot.rows[0]
            .iter()
            .map(|cell| serde_json::from_str(cell.get()).expect("JSON"))
            .collect();
        assert_eq!(
            parsed,
            [serde_json::json!("a \"quoted\"\nline"), serde_json::json!("NaN")]
        );
    }

    fn wide_rows(rows: usize, columns: usize, chars: usize) -> Vec<Vec<Value>> {
        (0..rows)
            .map(|_| (0..columns).map(|_| Value::Text("x".repeat(chars))).collect())
            .collect()
    }

    #[test]
    fn a_string_weighs_as_the_macos_app_counts_it() {
        assert_eq!(quoted_bytes("abc"), 5);
        assert_eq!(quoted_bytes("a<b>&"), 2 + 2 + 18);
        assert_eq!(quoted_bytes("\"\\\n\r\t"), 2 + 10);
        assert_eq!(quoted_bytes("\u{1}\u{7f}"), 2 + 6 + 1);
        assert_eq!(quoted_bytes("é•"), 2 + 5);
    }

    #[test]
    fn rows_stop_before_the_one_that_would_cross_the_budget() {
        let columns = cols(&["c"]);
        // 29 bytes of header, then 200,005 a row: 22 rows fit in 4,500,000.
        let rows = wide_rows(30, 1, 200_000);

        let snapshot = snap(&columns, &rows, ResultExtent::complete(30), 1_000);

        assert_eq!(snapshot.rows.len(), 22);
        assert_eq!(snapshot.row_count, Some(30));
        assert!(snapshot.truncated());
        assert_eq!(snapshot_row_count(&columns, &rows, 1_000), Ok(22));
        assert_eq!(snapshot_row_count(&columns, &rows, 5), Ok(5));
    }

    #[test]
    fn a_first_row_over_the_budget_refuses_the_share() {
        let columns = cols(&[
            "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u",
            "v", "w",
        ]);
        let rows = wide_rows(1, columns.len(), 200_000);

        assert_eq!(
            build_snapshot(&columns, &rows, ResultExtent::complete(1), 10).err(),
            Some(SnapshotRefusal::FirstRow)
        );
        assert_eq!(snapshot_row_count(&columns, &rows, 10), Err(SnapshotRefusal::FirstRow));
    }

    #[test]
    fn a_snapshot_with_no_column_is_refused() {
        let rows = vec![vec![Value::Int(1)]];

        let refused = build_snapshot(&[], &rows, ResultExtent::complete(1), 10).err();

        assert_eq!(refused, Some(SnapshotRefusal::NoColumns));
        assert_eq!(snapshot_row_count(&[], &rows, 10), Err(SnapshotRefusal::NoColumns));
        assert_eq!(SnapshotRefusal::NoColumns.code(), "export.snapshot_no_columns");
    }

    #[test]
    fn a_cell_over_256_kib_refuses_the_share_and_one_at_it_goes() {
        let columns = cols(&["note"]);
        let at_limit = wide_rows(1, 1, MAX_SNAPSHOT_CELL_BYTES - 2);
        let over = wide_rows(1, 1, MAX_SNAPSHOT_CELL_BYTES - 1);

        assert_eq!(snap(&columns, &at_limit, ResultExtent::complete(1), 10).rows.len(), 1);
        assert_eq!(
            build_snapshot(&columns, &over, ResultExtent::complete(1), 10).err(),
            Some(SnapshotRefusal::Cell {
                column: "note".to_owned()
            })
        );
    }
}
