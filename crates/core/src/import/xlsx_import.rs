use std::io::Cursor;

use calamine::{DataRef, Reader, Xlsx, open_workbook_from_rs};

use super::csv_import::{ImportError, MAX_COLUMNS, MAX_FIELD_BYTES, MAX_FILE_BYTES, MAX_IMPORT_ROWS};

const ZIP_MAGIC: &[u8] = b"PK\x03\x04";

pub fn is_xlsx(bytes: &[u8]) -> bool {
    bytes.starts_with(ZIP_MAGIC)
}

pub fn xlsx_to_csv(bytes: &[u8]) -> Result<Vec<u8>, ImportError> {
    let mut workbook: Xlsx<_> = open_workbook_from_rs(Cursor::new(bytes)).map_err(|_| ImportError::NotSpreadsheet)?;
    for name in workbook.sheet_names() {
        let mut cells = workbook
            .worksheet_cells_reader(&name)
            .map_err(|_| ImportError::NotSpreadsheet)?;
        let mut writer = csv::WriterBuilder::new().flexible(true).from_writer(Vec::new());
        let mut row: Vec<String> = Vec::new();
        let mut current = None;
        let mut first_row = 0;
        let mut rows_written = 0usize;
        while let Some(cell) = cells.next_cell().map_err(|_| ImportError::NotSpreadsheet)? {
            let (row_index, column) = cell.get_position();
            let current_row = *current.get_or_insert_with(|| {
                first_row = row_index;
                row_index
            });
            if row_index != current_row {
                write_row(&mut writer, &mut row, &mut rows_written)?;
                for _ in current_row + 1..row_index {
                    write_row(&mut writer, &mut row, &mut rows_written)?;
                }
                current = Some(row_index);
            }
            let column = column as usize;
            if column >= MAX_COLUMNS {
                return Err(ImportError::TooManyColumns {
                    columns: column + 1,
                    limit: MAX_COLUMNS,
                });
            }
            if row.len() <= column {
                row.resize(column + 1, String::new());
            }
            let text = cell_text(cell.get_value());
            if text.len() > MAX_FIELD_BYTES {
                return Err(ImportError::FieldTooLong {
                    line: (row_index - first_row) as usize + 1,
                    limit: MAX_FIELD_BYTES,
                });
            }
            row[column] = text;
            if writer.get_ref().len() as u64 > MAX_FILE_BYTES {
                return Err(ImportError::FileTooLarge {
                    size: writer.get_ref().len() as u64,
                    limit: MAX_FILE_BYTES,
                });
            }
        }
        if current.is_some() {
            write_row(&mut writer, &mut row, &mut rows_written)?;
            return writer.into_inner().map_err(|_| ImportError::NotSpreadsheet);
        }
    }
    Err(ImportError::NoColumns)
}

fn write_row(
    writer: &mut csv::Writer<Vec<u8>>,
    row: &mut Vec<String>,
    rows_written: &mut usize,
) -> Result<(), ImportError> {
    if *rows_written > MAX_IMPORT_ROWS {
        return Err(ImportError::TooManyRows { limit: MAX_IMPORT_ROWS });
    }
    writer
        .write_record(row.iter())
        .map_err(|_| ImportError::NotSpreadsheet)?;
    row.clear();
    *rows_written += 1;
    Ok(())
}

fn cell_text(value: &DataRef<'_>) -> String {
    match value {
        DataRef::Empty | DataRef::Error(_) => String::new(),
        DataRef::Int(number) => number.to_string(),
        DataRef::Float(number) if number.fract() == 0.0 && number.abs() < 1e15 => format!("{number:.0}"),
        DataRef::Float(number) => number.to_string(),
        DataRef::Bool(flag) => flag.to_string(),
        DataRef::String(text) => text.clone(),
        DataRef::SharedString(text) => (*text).to_string(),
        DataRef::DateTimeIso(text) | DataRef::DurationIso(text) => text.clone(),
        DataRef::DateTime(stamp) => stamp.as_datetime().map_or_else(
            || stamp.as_f64().to_string(),
            |moment| {
                if moment.time() == chrono::NaiveTime::MIN {
                    moment.format("%Y-%m-%d").to_string()
                } else {
                    moment.format("%Y-%m-%d %H:%M:%S").to_string()
                }
            },
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_workbook_becomes_comma_separated_text() {
        let mut workbook = rust_xlsxwriter::Workbook::new();
        let sheet = workbook.add_worksheet();
        sheet.write_string(0, 0, "id").unwrap();
        sheet.write_string(0, 1, "note").unwrap();
        sheet.write_number(1, 0, 7).unwrap();
        sheet.write_string(1, 1, "a,b").unwrap();
        sheet.write_number(3, 0, 1.5).unwrap();
        let bytes = workbook.save_to_buffer().unwrap();

        assert!(is_xlsx(&bytes));
        let csv = String::from_utf8(xlsx_to_csv(&bytes).unwrap()).unwrap();
        assert_eq!(csv, "id,note\n7,\"a,b\"\n\"\"\n1.5\n");
    }

    #[test]
    fn text_that_is_not_a_workbook_is_refused() {
        assert!(!is_xlsx(b"a,b\n1,2\n"));
        assert_eq!(xlsx_to_csv(b"PK\x03\x04 not really"), Err(ImportError::NotSpreadsheet));
    }

    #[test]
    fn an_empty_workbook_has_no_columns() {
        let mut workbook = rust_xlsxwriter::Workbook::new();
        workbook.add_worksheet();
        let bytes = workbook.save_to_buffer().unwrap();
        assert_eq!(xlsx_to_csv(&bytes), Err(ImportError::NoColumns));
    }
}
