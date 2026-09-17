use rust_xlsxwriter::{Format, Workbook, Worksheet};

use super::{EncodeError, cell_text};
use crate::column::ResultColumn;
use crate::value::{Temporal, Value};

/// What one sheet holds. Past this, Excel refuses to open the file at
/// all, so the export says so instead of writing one nobody can read.
const MAX_ROWS: usize = 1_048_576;
const MAX_COLUMNS: usize = 16_384;

/// The whole point of XLSX over CSV is that a number arrives as a
/// number, so each value is written in the type Excel has for it and
/// dates carry a display format rather than a serial number.
///
/// A string cell is never read as a formula, whatever it starts with,
/// so unlike CSV this needs no formula neutralising.
pub fn render_xlsx(columns: &[ResultColumn], rows: &[Vec<Value>], sheet_name: &str) -> Result<Vec<u8>, EncodeError> {
    // The header takes a row, so the data has one fewer to fill.
    if rows.len() + 1 > MAX_ROWS {
        return Err(EncodeError::TooManyRows {
            got: rows.len(),
            limit: MAX_ROWS - 1,
        });
    }
    if columns.len() > MAX_COLUMNS {
        return Err(EncodeError::TooManyColumns {
            got: columns.len(),
            limit: MAX_COLUMNS,
        });
    }

    let mut workbook = Workbook::new();
    let sheet = workbook.add_worksheet();
    sheet.set_name(sheet_title(sheet_name)).map_err(xlsx_error)?;

    let header = Format::new().set_bold();
    for (index, column) in columns.iter().enumerate() {
        sheet
            .write_string_with_format(0, index as u16, &column.name, &header)
            .map_err(xlsx_error)?;
    }
    // A header that scrolls away is a sheet of unlabelled numbers.
    sheet.set_freeze_panes(1, 0).map_err(xlsx_error)?;

    let date = Format::new().set_num_format("yyyy-mm-dd");
    let timestamp = Format::new().set_num_format("yyyy-mm-dd hh:mm:ss");
    for (row_index, row) in rows.iter().enumerate() {
        let sheet_row = (row_index + 1) as u32;
        for (column_index, value) in row.iter().enumerate() {
            if column_index >= MAX_COLUMNS {
                break;
            }
            write_cell(sheet, sheet_row, column_index as u16, columns, value, &date, &timestamp)?;
        }
    }

    workbook.save_to_buffer().map_err(xlsx_error)
}

fn write_cell(
    sheet: &mut Worksheet,
    row: u32,
    column: u16,
    columns: &[ResultColumn],
    value: &Value,
    date: &Format,
    timestamp: &Format,
) -> Result<(), EncodeError> {
    match value {
        // A blank cell, not an empty string: Excel's COUNT and AVERAGE
        // read the two differently, and NULL is the absent one.
        Value::Null => Ok(()),
        Value::Bool(flag) => sheet.write_boolean(row, column, *flag).map(drop),
        Value::Int(number) => sheet.write_number(row, column, *number as f64).map(drop),
        Value::UInt(number) => sheet.write_number(row, column, *number as f64).map(drop),
        Value::Float32(number) => sheet.write_number(row, column, f64::from(*number)).map(drop),
        Value::Float64(number) => sheet.write_number(row, column, *number).map(drop),
        Value::Date(Temporal::Finite(day)) => sheet.write_datetime_with_format(row, column, day, date).map(drop),
        Value::Timestamp(Temporal::Finite(at)) => {
            sheet.write_datetime_with_format(row, column, at, timestamp).map(drop)
        }
        // A sheet cell carries no zone, so an offset timestamp goes in
        // at UTC. The text formats keep the offset; this one cannot.
        Value::TimestampTz(Temporal::Finite(at)) => sheet
            .write_datetime_with_format(row, column, at.utc(), timestamp)
            .map(drop),
        // A decimal is written as a number only when Excel can hold it:
        // a sheet stores every number as an f64, so one that does not
        // round-trip would be silently changed. The rest keep their
        // digits as text, which is what the user asked the database
        // for.
        Value::Decimal(_) | Value::WideInt(_) => match exact_number(columns, column, value) {
            Some(number) => sheet.write_number(row, column, number).map(drop),
            None => write_text(sheet, row, column, columns, value),
        },
        _ => write_text(sheet, row, column, columns, value),
    }
    .map_err(xlsx_error)
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

/// The value as an f64, when that f64 prints back as the same digits.
/// `None` when it does not, which is the case this exists to catch.
fn exact_number(columns: &[ResultColumn], column: u16, value: &Value) -> Option<f64> {
    let text = cell_text(columns, column as usize, value)?;
    let parsed: f64 = text.parse().ok()?;
    // `{}` on an f64 prints the shortest form that round-trips, so
    // comparing against it is comparing the value, not the spelling.
    match format!("{parsed}") == text {
        true => Some(parsed),
        false => None,
    }
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

fn xlsx_error(error: rust_xlsxwriter::XlsxError) -> EncodeError {
    EncodeError::Xlsx(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::test_columns::{col, cols};

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
    fn a_result_wider_than_a_sheet_is_refused() {
        let columns: Vec<ResultColumn> = (0..MAX_COLUMNS + 1).map(|index| col(&index.to_string())).collect();

        let error = render_xlsx(&columns, &[], "Results").expect_err("too wide");

        assert!(matches!(error, EncodeError::TooManyColumns { .. }), "{error:?}");
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
