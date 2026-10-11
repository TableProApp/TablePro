use super::*;
use crate::export::test_support::column;
use crate::export::{CsvDecimal, CsvDelimiter, render_csv};
use std::io;

struct Sink {
    bytes: Vec<u8>,
    fail_after: usize,
    interrupt: bool,
}

impl Write for Sink {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.interrupt {
            self.interrupt = false;
            return Err(io::ErrorKind::Interrupted.into());
        }
        if self.bytes.len() >= self.fail_after {
            return Err(io::Error::other("fixture write failure"));
        }
        let count = bytes.len().min(3).min(self.fail_after - self.bytes.len());
        self.bytes.extend_from_slice(&bytes[..count]);
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn render(format: ResultFormat, output: &mut dyn Write) -> Result<(), ExportError> {
    let data = QueryResult {
        columns: vec![column("id"), column("text")],
        rows: vec![vec![Value::Int(i64::MAX), Value::Text("東京 & 'quote'\nnext".into())]],
        truncated: false,
    };
    let options = CsvOptions::default();
    let export = ResultExport {
        format,
        csv: &options,
        sql: Some(SqlTarget {
            driver_id: "sqlite",
            schema: None,
            table: "items",
        }),
    };
    let mut writer = writer_for(&export, data.rows.len())?;
    writer.begin(output, &data.columns)?;
    writer.write_row(output, 0, &data.rows[0])?;
    writer.finish(output)
}

#[test]
fn value_contract_text_exports_retry_interruptions_and_complete_short_writes() {
    for format in [
        ResultFormat::Csv,
        ResultFormat::Json,
        ResultFormat::Markdown,
        ResultFormat::Html,
        ResultFormat::Xml,
        ResultFormat::Sql,
    ] {
        let mut expected = Vec::new();
        render(format, &mut expected).unwrap();
        let mut actual = Sink {
            bytes: vec![],
            fail_after: usize::MAX,
            interrupt: true,
        };
        render(format, &mut actual).unwrap();
        assert_eq!(actual.bytes, expected, "{format:?}");
        assert!(String::from_utf8(actual.bytes).unwrap().contains("東京"), "{format:?}");
    }
}

#[test]
fn value_contract_streamed_csv_matches_renderer_with_and_without_header() {
    let columns = vec![column("value"), column("note")];
    let rows = vec![vec![
        Value::Decimal("12.30".parse().unwrap()),
        Value::Text("東京;line\nbreak".into()),
    ]];

    for header_row in [true, false] {
        let options = CsvOptions {
            delimiter: CsvDelimiter::Semicolon,
            decimal: CsvDecimal::Comma,
            line_break_to_space: true,
            header_row,
            ..CsvOptions::default()
        };
        let expected = render_csv(&columns, &rows, &options);
        let data = QueryResult {
            columns: columns.clone(),
            rows: rows.clone(),
            truncated: false,
        };
        let export = ResultExport {
            format: ResultFormat::Csv,
            csv: &options,
            sql: None,
        };
        let mut writer = writer_for(&export, data.rows.len()).unwrap();
        let mut actual = Vec::new();
        writer.begin(&mut actual, &data.columns).unwrap();
        for (index, row) in data.rows.iter().enumerate() {
            writer.write_row(&mut actual, index, row).unwrap();
        }
        writer.finish(&mut actual).unwrap();

        assert_eq!(actual, expected.as_bytes(), "header_row={header_row}");
    }
}

#[test]
fn value_contract_every_export_propagates_destination_write_failure() {
    for format in [
        ResultFormat::Csv,
        ResultFormat::Json,
        ResultFormat::Markdown,
        ResultFormat::Html,
        ResultFormat::Xml,
        ResultFormat::Sql,
        ResultFormat::Xlsx,
    ] {
        for fail_after in [0, 3] {
            let mut sink = Sink {
                bytes: vec![],
                fail_after,
                interrupt: false,
            };
            let error = render(format, &mut sink).unwrap_err();
            assert!(matches!(error, ExportError::Write(_)), "{format:?}: {error:?}");
            assert!(
                error.to_string().contains("fixture write failure"),
                "{format:?}: {error}"
            );
            assert_eq!(sink.bytes.len(), fail_after, "{format:?}");
        }
    }
}
