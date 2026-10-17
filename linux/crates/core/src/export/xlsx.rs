use std::sync::Arc;

use rust_xlsxwriter::{Format, Workbook, Worksheet};

use super::encoder::column_name;
use super::{EncodeError, RenderError, cell_text};
use crate::column::ResultColumn;
use crate::value::{Temporal, Value};

/// What one sheet holds. Past this, Excel refuses to open the file at
/// all, so the export says so instead of writing one nobody can read.
const MAX_ROWS: usize = 1_048_576;
const MAX_COLUMNS: usize = 16_384;

/// The rows a sheet holds under its header row.
pub const XLSX_MAX_DATA_ROWS: usize = MAX_ROWS - 1;

/// A whole result as one workbook.
pub fn render_xlsx(columns: &[ResultColumn], rows: &[Vec<Value>], sheet_name: &str) -> Result<Vec<u8>, RenderError> {
    if rows.len() > XLSX_MAX_DATA_ROWS {
        return Err(RenderError::TooManyRows {
            got: rows.len(),
            limit: XLSX_MAX_DATA_ROWS,
        });
    }
    let mut writer = XlsxSheetWriter::new(columns.into(), sheet_name)?;
    writer.write_rows(rows)?;
    writer.finish()
}

/// A one-sheet workbook written a batch of rows at a time.
///
/// The sheet is in rust_xlsxwriter's constant memory mode: it keeps the
/// row it is writing and spills the rows before it to a temporary file,
/// so an export of a million rows holds none of them. Only the finished
/// workbook, compressed, is held at the end, since a zip archive is
/// written whole.
///
/// The whole point of XLSX over CSV is that a number arrives as a
/// number, so each value is written in the type Excel has for it and
/// dates carry a display format rather than a serial number.
///
/// A string cell is never read as a formula, whatever it starts with,
/// so unlike CSV this needs no formula neutralising.
pub struct XlsxSheetWriter {
    workbook: Workbook,
    columns: Arc<[ResultColumn]>,
    rows: usize,
    date: Format,
    timestamp: Format,
}

impl XlsxSheetWriter {
    pub fn new(columns: Arc<[ResultColumn]>, sheet_name: &str) -> Result<Self, RenderError> {
        if columns.len() > MAX_COLUMNS {
            return Err(RenderError::TooManyColumns {
                got: columns.len(),
                limit: MAX_COLUMNS,
            });
        }
        let mut workbook = Workbook::new();
        let sheet = workbook.add_worksheet_with_constant_memory();
        sheet.set_name(sheet_title(sheet_name)).map_err(xlsx_error)?;
        let header = Format::new().set_bold();
        for (index, column) in columns.iter().enumerate() {
            sheet
                .write_string_with_format(0, index as u16, &column.name, &header)
                .map_err(xlsx_error)?;
        }
        // A header that scrolls away is a sheet of unlabelled numbers.
        sheet.set_freeze_panes(1, 0).map_err(xlsx_error)?;
        Ok(Self {
            workbook,
            columns,
            rows: 0,
            date: Format::new().set_num_format("yyyy-mm-dd"),
            timestamp: Format::new().set_num_format("yyyy-mm-dd hh:mm:ss"),
        })
    }

    /// The data rows written so far.
    pub fn rows(&self) -> usize {
        self.rows
    }

    /// Write `rows` under the ones already written. A sheet past its
    /// last row cannot be opened, so the batch that would fill it past
    /// that is refused whole.
    pub fn write_rows(&mut self, rows: &[Vec<Value>]) -> Result<(), RenderError> {
        let got = self.rows + rows.len();
        if got > XLSX_MAX_DATA_ROWS {
            return Err(RenderError::TooManyRows {
                got,
                limit: XLSX_MAX_DATA_ROWS,
            });
        }
        let Self {
            workbook,
            columns,
            rows: written,
            date,
            timestamp,
        } = self;
        let sheet = workbook.worksheet_from_index(0).map_err(xlsx_error)?;
        for row in rows {
            // The header takes the first row.
            let sheet_row = (*written + 1) as u32;
            for (column_index, value) in row.iter().enumerate() {
                if column_index >= MAX_COLUMNS {
                    break;
                }
                write_cell(sheet, sheet_row, column_index as u16, columns, value, date, timestamp)?;
            }
            *written += 1;
        }
        Ok(())
    }

    pub fn finish(mut self) -> Result<Vec<u8>, RenderError> {
        self.workbook.save_to_buffer().map_err(xlsx_error)
    }
}

fn write_cell(
    sheet: &mut Worksheet,
    row: u32,
    column: u16,
    columns: &[ResultColumn],
    value: &Value,
    date: &Format,
    timestamp: &Format,
) -> Result<(), RenderError> {
    match value {
        // A blank cell, not an empty string: Excel's COUNT and AVERAGE
        // read the two differently, and NULL is the absent one.
        Value::Null => Ok(()),
        // Left blank, it would read as a NULL the table does not hold.
        Value::Undecodable(_) => {
            return Err(RenderError::Encode(EncodeError::Undecodable {
                column: column_name(columns, usize::from(column)),
            }));
        }
        Value::Bool(flag) => sheet.write_boolean(row, column, *flag).map(drop),
        Value::Date(Temporal::Finite(day)) => sheet.write_datetime_with_format(row, column, day, date).map(drop),
        Value::Timestamp(Temporal::Finite(at)) => {
            sheet.write_datetime_with_format(row, column, at, timestamp).map(drop)
        }
        // A sheet cell carries no zone, so an offset timestamp goes in
        // at UTC. The text formats keep the offset; this one cannot.
        Value::TimestampTz(Temporal::Finite(at)) => sheet
            .write_datetime_with_format(row, column, at.utc(), timestamp)
            .map(drop),
        _ => match sheet_number(columns, column, value) {
            Some(number) => sheet.write_number(row, column, number).map(drop),
            None => write_text(sheet, row, column, columns, value),
        },
    }
    .map_err(xlsx_error)
}

/// The number a cell goes in as, or `None` for one that goes in as
/// text.
///
/// An integer or decimal is a number only when Excel can hold it: a
/// sheet stores every number as an f64, so a `bigint` past 2^53 or a
/// long decimal would be silently changed. The rest keep their digits
/// as text, which is what the user asked the database for.
fn sheet_number(columns: &[ResultColumn], column: u16, value: &Value) -> Option<f64> {
    match value {
        Value::Float32(number) => Some(real_number(*number)),
        Value::Float64(number) => Some(*number),
        Value::Int(_) | Value::UInt(_) | Value::Decimal(_) | Value::WideInt(_) => exact_number(columns, column, value),
        _ => None,
    }
}

/// Everything else goes in as the same text the other exports write,
/// so a cell reads the same whichever format the user picked.
fn write_text(
    sheet: &mut Worksheet,
    row: u32,
    column: u16,
    columns: &[ResultColumn],
    value: &Value,
) -> Result<(), rust_xlsxwriter::XlsxError> {
    match cell_text(columns, column as usize, value) {
        Some(text) => sheet.write_string(row, column, text).map(drop),
        None => Ok(()),
    }
}

/// The value as an f64, when that f64 prints back as the same number.
/// `None` when it does not, which is the case this exists to catch.
fn exact_number(columns: &[ResultColumn], column: u16, value: &Value) -> Option<f64> {
    let text = cell_text(columns, column as usize, value)?;
    let parsed: f64 = text.parse().ok()?;
    // `{}` on an f64 prints the shortest form that round-trips, so
    // comparing against it is comparing the value, not the spelling.
    // The zeros a `numeric(10,2)` pads `1.50` with are spelling.
    match without_scale_padding(&format!("{parsed}")) == without_scale_padding(&text) {
        true => Some(parsed),
        false => None,
    }
}

fn without_scale_padding(text: &str) -> &str {
    match text.contains('.') {
        true => text.trim_end_matches('0').trim_end_matches('.'),
        false => text,
    }
}

/// The double a `real`'s own shortest digits name. Widening its bits
/// instead hands the sheet `0.100000001490116` for a `real` holding 0.1.
fn real_number(number: f32) -> f64 {
    number.to_string().parse().unwrap_or(f64::from(number))
}

/// A sheet name Excel accepts: at most 31 characters, none of
/// `[]:*?/\`, not empty, and not wrapped in apostrophes.
fn sheet_title(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|character| match character {
            '[' | ']' | ':' | '*' | '?' | '/' | '\\' => '_',
            other => other,
        })
        .take(31)
        .collect();
    let trimmed = cleaned.trim().trim_matches('\'');
    match trimmed.is_empty() {
        true => "Sheet1".to_owned(),
        false => trimmed.to_owned(),
    }
}

fn xlsx_error(error: rust_xlsxwriter::XlsxError) -> RenderError {
    RenderError::Xlsx(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::ColumnKind;
    use crate::export::test_columns::{col, cols, typed};

    fn workbook_bytes(columns: &[ResultColumn], rows: &[Vec<Value>]) -> Vec<u8> {
        render_xlsx(columns, rows, "Results").expect("render")
    }

    #[test]
    fn a_workbook_is_a_zip_archive_excel_can_open() {
        let bytes = workbook_bytes(&cols(&["a"]), &[vec![Value::Int(1)]]);

        // The XLSX container is a zip: "PK\x03\x04" is its signature.
        assert_eq!(&bytes[..4], b"PK\x03\x04");
        assert!(bytes.len() > 200, "a workbook of {} bytes", bytes.len());
    }

    #[test]
    fn a_sheet_name_excel_would_refuse_is_cleaned_up() {
        assert_eq!(sheet_title("orders"), "orders");
        assert_eq!(sheet_title("public/orders"), "public_orders");
        assert_eq!(sheet_title("a[b]c:d*e?f"), "a_b_c_d_e_f");
        assert_eq!(sheet_title("   "), "Sheet1");
        assert_eq!(sheet_title("'quoted'"), "quoted");
        assert_eq!(sheet_title(&"x".repeat(40)).chars().count(), 31);
    }

    #[test]
    fn a_name_excel_refuses_does_not_fail_the_export() {
        let bytes = render_xlsx(&cols(&["a"]), &[vec![Value::Int(1)]], "public/orders:2026").expect("render");

        assert_eq!(&bytes[..4], b"PK\x03\x04");
    }

    #[test]
    fn a_decimal_that_an_f64_holds_exactly_is_written_as_a_number() {
        let columns = cols(&["amount"]);
        let value = Value::Decimal("1.25".parse().expect("decimal"));

        assert_eq!(exact_number(&columns, 0, &value), Some(1.25));
    }

    #[test]
    fn a_decimal_an_f64_would_change_stays_text() {
        let columns = cols(&["amount"]);
        // Nineteen significant digits, which an f64 cannot hold.
        let value = Value::Decimal("1234567890123456789".parse().expect("decimal"));

        assert_eq!(exact_number(&columns, 0, &value), None);
    }

    #[test]
    fn a_wide_integer_past_an_f64_stays_text() {
        let columns = cols(&["id"]);
        let value = Value::WideInt("170141183460469231731687303715884105727".parse().expect("wide"));

        assert_eq!(exact_number(&columns, 0, &value), None);
    }

    #[test]
    fn a_decimal_padded_to_its_scale_is_still_a_number() {
        let columns = vec![typed(
            "amount",
            "numeric(10,2)",
            ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2),
            },
        )];

        for (digits, number) in [("1.5", 1.5), ("2", 2.0), ("-0.10", -0.1), ("100", 100.0)] {
            let value = Value::Decimal(digits.parse().expect("decimal"));
            assert_eq!(sheet_number(&columns, 0, &value), Some(number), "{digits}");
        }
    }

    #[test]
    fn an_integer_past_an_f64_stays_text() {
        let columns = cols(&["id"]);

        assert_eq!(sheet_number(&columns, 0, &Value::Int(42)), Some(42.0));
        assert_eq!(
            sheet_number(&columns, 0, &Value::Int(-(1 << 53))),
            Some(-9_007_199_254_740_992.0)
        );
        assert_eq!(sheet_number(&columns, 0, &Value::Int((1 << 53) + 1)), None);
        assert_eq!(sheet_number(&columns, 0, &Value::UInt(u64::MAX)), None);
    }

    #[test]
    fn a_real_is_written_as_the_number_it_prints_as() {
        let columns = cols(&["r"]);

        assert_eq!(sheet_number(&columns, 0, &Value::Float32(0.1)), Some(0.1));
        assert_eq!(sheet_number(&columns, 0, &Value::Float32(-3.3)), Some(-3.3));
        assert!(sheet_number(&columns, 0, &Value::Float32(f32::NAN)).is_some_and(f64::is_nan));
        assert_eq!(sheet_number(&columns, 0, &Value::Text("1".to_owned())), None);
    }

    #[test]
    fn a_result_wider_than_a_sheet_is_refused() {
        let columns: Vec<ResultColumn> = (0..MAX_COLUMNS + 1).map(|index| col(&index.to_string())).collect();

        let error = render_xlsx(&columns, &[], "Results").expect_err("too wide");

        assert!(matches!(error, RenderError::TooManyColumns { .. }), "{error:?}");
    }

    fn sheet_xml(bytes: &[u8]) -> String {
        use std::io::Read;

        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("a zip archive");
        let mut sheet = archive.by_name("xl/worksheets/sheet1.xml").expect("the sheet");
        let mut xml = String::new();
        sheet.read_to_string(&mut xml).expect("the sheet's XML");
        xml
    }

    /// Rows go into the sheet a batch at a time, as an export reads
    /// them, and every one of them lands under the header.
    #[test]
    fn a_sheet_written_in_batches_holds_every_row() {
        let columns: Arc<[ResultColumn]> = cols(&["id", "name"]).into();
        let batch = |first: i64| -> Vec<Vec<Value>> {
            (first..first + 1_000)
                .map(|id| vec![Value::Int(id), Value::Text(format!("name {id}"))])
                .collect()
        };
        let mut writer = XlsxSheetWriter::new(columns, "Results").expect("the writer");

        writer.write_rows(&batch(0)).expect("the first batch");
        writer.write_rows(&batch(1_000)).expect("the second batch");
        assert_eq!(writer.rows(), 2_000);
        let xml = sheet_xml(&writer.finish().expect("the workbook"));

        assert_eq!(xml.matches("<row ").count(), 2_001, "the header and every row");
        assert!(
            xml.contains("name 0<") && xml.contains("name 1999<"),
            "a row is missing"
        );
    }

    #[test]
    fn a_batch_past_the_last_row_is_refused() {
        let mut writer = XlsxSheetWriter::new(cols(&["a"]).into(), "Results").expect("the writer");
        writer.rows = XLSX_MAX_DATA_ROWS - 1;

        let refused = writer.write_rows(&[vec![Value::Int(1)], vec![Value::Int(2)]]);

        assert!(
            matches!(refused, Err(RenderError::TooManyRows { got, .. }) if got == XLSX_MAX_DATA_ROWS + 1),
            "{refused:?}"
        );
    }

    fn undecodable() -> Value {
        Value::Undecodable(Box::new(crate::value::UndecodedValue {
            type_name: "text".to_owned(),
            reason: crate::value::UndecodableReason::InvalidEncoding,
        }))
    }

    #[test]
    fn an_unreadable_value_is_refused_rather_than_written_as_a_blank() {
        let refused = render_xlsx(&cols(&["id", "body"]), &[vec![Value::Int(1), undecodable()]], "Results");

        assert!(
            matches!(&refused, Err(RenderError::Encode(EncodeError::Undecodable { column })) if column == "body"),
            "{refused:?}"
        );
    }

    #[test]
    fn every_value_kind_writes_without_failing() {
        let columns = cols(&["a", "b", "c", "d", "e", "f", "g"]);
        let rows = vec![vec![
            Value::Null,
            Value::Bool(true),
            Value::Text("=1+1".to_owned()),
            Value::Bytes(vec![1, 2, 3]),
            Value::Uuid(uuid::Uuid::nil()),
            Value::Date(Temporal::Infinity),
            Value::Float64(f64::NAN),
        ]];

        let bytes = render_xlsx(&columns, &rows, "Results").expect("render");

        assert_eq!(&bytes[..4], b"PK\x03\x04");
    }
}
