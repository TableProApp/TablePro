use std::path::Path;

use super::csv::CsvOptions;
use super::error::ExportError;
use super::file::{ResultExport, ResultFormat, writer_for};
use super::value_to_text;
use super::write_atomically_checked;
use crate::query::{ColumnInfo, Value};

pub type RowPage = Vec<Vec<Value>>;

fn refuse_marker_collision(row: &[Value], index: usize, options: &CsvOptions) -> Result<(), ExportError> {
    let Some(marker) = options.null_marker.as_deref() else {
        return Ok(());
    };
    if row.iter().any(|value| value_to_text(value).as_deref() == Some(marker)) {
        return Err(ExportError::NullMarkerCollision {
            marker: marker.to_string(),
            row: index + 1,
        });
    }
    Ok(())
}

pub fn write_paged_file(
    path: &Path,
    columns: &[ColumnInfo],
    row_count: usize,
    export: &ResultExport<'_>,
    mut next_page: impl FnMut() -> Result<Option<RowPage>, ExportError>,
    cancelled: impl Fn() -> bool,
    progress: impl Fn(usize),
) -> Result<(), ExportError> {
    let check = || {
        if cancelled() {
            Err(ExportError::Cancelled)
        } else {
            Ok(())
        }
    };
    check()?;
    let mut writer = writer_for(export, row_count)?;
    let csv_marker = matches!(export.format, ResultFormat::Csv);
    write_atomically_checked(
        path,
        |output| {
            writer.begin(output, columns)?;
            let mut index = 0;
            while let Some(page) = next_page()? {
                for row in &page {
                    check()?;
                    if csv_marker {
                        refuse_marker_collision(row, index, export.csv)?;
                    }
                    writer.write_row(output, index, row)?;
                    index += 1;
                    progress(index);
                }
            }
            writer.finish(output)
        },
        check,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::test_support::column;
    use std::cell::Cell;

    fn page(range: std::ops::Range<i64>) -> RowPage {
        range
            .map(|n| vec![Value::Int(n), Value::Text(format!("row {n}"))])
            .collect()
    }

    fn csv_export(options: &CsvOptions) -> ResultExport<'_> {
        ResultExport {
            format: ResultFormat::Csv,
            csv: options,
            sql: None,
        }
    }

    fn pages(mut all: Vec<RowPage>) -> impl FnMut() -> Result<Option<RowPage>, ExportError> {
        all.reverse();
        move || Ok(all.pop())
    }

    #[test]
    fn every_page_lands_in_one_file_in_order() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("out.csv");
        let options = CsvOptions::default();
        let seen = Cell::new(0);
        write_paged_file(
            &path,
            &[column("id"), column("text")],
            5,
            &csv_export(&options),
            pages(vec![page(0..2), page(2..5)]),
            || false,
            |rows| seen.set(rows),
        )
        .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "id,text");
        assert_eq!(lines.len(), 6);
        assert_eq!(lines[5], "4,row 4");
        assert_eq!(seen.get(), 5);
    }

    #[test]
    fn a_failing_page_publishes_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("out.csv");
        let options = CsvOptions::default();
        let mut served = false;
        let result = write_paged_file(
            &path,
            &[column("id"), column("text")],
            0,
            &csv_export(&options),
            || {
                if served {
                    return Err(ExportError::Source("connection lost".into()));
                }
                served = true;
                Ok(Some(page(0..3)))
            },
            || false,
            |_| {},
        );
        assert!(matches!(result, Err(ExportError::Source(_))));
        assert!(!path.exists());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    }

    #[test]
    fn cancelling_between_rows_publishes_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("out.csv");
        let options = CsvOptions::default();
        let rows_written = Cell::new(0);
        let result = write_paged_file(
            &path,
            &[column("id"), column("text")],
            0,
            &csv_export(&options),
            pages(vec![page(0..100)]),
            || rows_written.get() >= 10,
            |rows| rows_written.set(rows),
        );
        assert!(matches!(result, Err(ExportError::Cancelled)));
        assert!(!path.exists());
    }

    #[test]
    fn a_value_equal_to_the_null_marker_is_refused_instead_of_written() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("out.csv");
        let options = CsvOptions {
            null_marker: Some("\\N".into()),
            ..CsvOptions::default()
        };
        let mut rows = page(0..3);
        rows[2][1] = Value::Text("\\N".into());
        let result = write_paged_file(
            &path,
            &[column("id"), column("text")],
            0,
            &csv_export(&options),
            pages(vec![rows]),
            || false,
            |_| {},
        );
        assert!(matches!(result, Err(ExportError::NullMarkerCollision { row: 3, .. })));
        assert!(!path.exists());
    }

    #[test]
    fn json_streams_pages_into_one_valid_document() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("out.json");
        let options = CsvOptions::default();
        let export = ResultExport {
            format: ResultFormat::Json,
            csv: &options,
            sql: None,
        };
        write_paged_file(
            &path,
            &[column("id"), column("text")],
            0,
            &export,
            pages(vec![page(0..2), Vec::new(), page(2..4)]),
            || false,
            |_| {},
        )
        .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(parsed.as_array().unwrap().len(), 4);
    }
}
