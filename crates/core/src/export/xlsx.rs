use std::io::Write;

use chrono::{Datelike, Timelike};
use rust_xlsxwriter::{Format, Workbook, Worksheet, XlsxError};

use super::error::ExportError;
use super::file::ResultWriter;
use super::value_to_text;
use crate::query::{ColumnInfo, Value};

/// A worksheet holds 1,048,576 rows including the header, so one fewer
/// data row fits than the sheet limit suggests.
pub const MAX_WORKBOOK_ROWS: usize = 1_048_575;

struct CellFormats {
    date: Format,
    time: Format,
    date_time: Format,
}

impl CellFormats {
    fn new() -> Self {
        Self {
            date: Format::new().set_num_format("yyyy\\-mm\\-dd"),
            time: Format::new().set_num_format("hh:mm:ss"),
            date_time: Format::new().set_num_format("yyyy\\-mm\\-dd hh:mm:ss"),
        }
    }
}

pub(crate) struct XlsxWriter {
    sheet: Worksheet,
    formats: CellFormats,
}

impl XlsxWriter {
    pub(crate) fn new(rows: usize) -> Result<Self, ExportError> {
        if rows > MAX_WORKBOOK_ROWS {
            return Err(ExportError::WorkbookTooLarge {
                limit: MAX_WORKBOOK_ROWS,
                rows,
            });
        }
        Ok(Self {
            sheet: Worksheet::new(),
            formats: CellFormats::new(),
        })
    }
}

impl ResultWriter for XlsxWriter {
    fn begin(&mut self, _output: &mut dyn Write, columns: &[ColumnInfo]) -> Result<(), ExportError> {
        let header = Format::new().set_bold();
        for (index, info) in columns.iter().enumerate() {
            self.sheet
                .write_string_with_format(0, cell_column(index)?, &info.name, &header)?;
        }
        Ok(())
    }

    fn write_row(&mut self, _output: &mut dyn Write, index: usize, row: &[Value]) -> Result<(), ExportError> {
        if index >= MAX_WORKBOOK_ROWS {
            return Err(ExportError::WorkbookTooLarge {
                limit: MAX_WORKBOOK_ROWS,
                rows: index.saturating_add(1),
            });
        }
        let target = (index + 1) as u32;
        for (column, value) in row.iter().enumerate() {
            let cell_column = cell_column(column)?;
            if matches!(value, Value::Text(text) if text.is_empty()) {
                return Err(ExportError::WorkbookEmptyText {
                    row: index + 1,
                    column: column + 1,
                });
            }
            write_cell(&mut self.sheet, target, cell_column, value, &self.formats)?;
        }
        Ok(())
    }

    fn finish(&mut self, output: &mut dyn Write) -> Result<(), ExportError> {
        let mut workbook = Workbook::new();
        workbook.push_worksheet(std::mem::replace(&mut self.sheet, Worksheet::new()));
        let bytes = workbook.save_to_buffer()?;
        output.write_all(&bytes)?;
        Ok(())
    }
}

fn cell_column(index: usize) -> Result<u16, ExportError> {
    if index >= 16_384 {
        return Err(ExportError::WorkbookColumnLimit {
            columns: index.saturating_add(1),
        });
    }
    Ok(index as u16)
}

fn write_cell(
    sheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: &Value,
    formats: &CellFormats,
) -> Result<(), XlsxError> {
    match value {
        Value::Null => Ok(()),
        Value::Bool(value) => sheet.write_boolean(row, column, *value).map(drop),
        Value::Int(value) if value.unsigned_abs() <= 999_999_999_999_999 => {
            sheet.write_number(row, column, *value as f64).map(drop)
        }
        Value::Int(value) => sheet.write_string(row, column, value.to_string()).map(drop),
        Value::Float(value) if excel_safe_float_number(*value) => sheet.write_number(row, column, *value).map(drop),
        Value::Decimal(value) => sheet.write_string(row, column, value.to_string()).map(drop),
        Value::Date(value) if (1900..=9999).contains(&value.year()) => {
            sheet.write_with_format(row, column, value, &formats.date).map(drop)
        }
        Value::Time(value) if value.nanosecond() == 0 => {
            sheet.write_with_format(row, column, value, &formats.time).map(drop)
        }
        Value::DateTime(value) if (1900..=9999).contains(&value.year()) && value.nanosecond() == 0 => sheet
            .write_with_format(row, column, value, &formats.date_time)
            .map(drop),
        other => match value_to_text(other) {
            Some(text) => sheet.write_string(row, column, text).map(drop),
            None => Ok(()),
        },
    }
}

fn excel_safe_float_number(value: f64) -> bool {
    if !value.is_finite() {
        return false;
    }
    if value == 0.0 {
        return !value.is_sign_negative();
    }
    let magnitude = value.abs();
    if !(2.2251e-308..=9.99999999999999e307).contains(&magnitude) {
        return false;
    }
    let decimal = value.to_string();
    let digits: Vec<_> = decimal
        .split(['e', 'E'])
        .next()
        .unwrap_or(&decimal)
        .bytes()
        .filter(u8::is_ascii_digit)
        .collect();
    let Some(first) = digits.iter().position(|digit| *digit != b'0') else {
        return true;
    };
    let last = digits.iter().rposition(|digit| *digit != b'0').unwrap_or(first);
    last - first < 15
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::test_support::column;

    fn workbook_parts(values: &[Value]) -> (String, String) {
        use std::io::{Cursor, Read};

        let mut writer = XlsxWriter::new(values.len()).unwrap();
        let mut output = Vec::new();
        writer.begin(&mut output, &[column("value")]).unwrap();
        for (index, value) in values.iter().enumerate() {
            writer
                .write_row(&mut output, index, std::slice::from_ref(value))
                .unwrap();
        }
        writer.finish(&mut output).unwrap();
        let mut archive = zip::ZipArchive::new(Cursor::new(output)).unwrap();
        let mut sheet = String::new();
        archive
            .by_name("xl/worksheets/sheet1.xml")
            .unwrap()
            .read_to_string(&mut sheet)
            .unwrap();
        let mut strings = String::new();
        archive
            .by_name("xl/sharedStrings.xml")
            .unwrap()
            .read_to_string(&mut strings)
            .unwrap();
        (sheet, strings)
    }

    #[test]
    fn value_contract_workbook_preserves_wide_integers_and_exact_decimals_as_text() {
        let corpus: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../testdata/value-contract.json"
        )))
        .unwrap();
        let mut values = vec![Value::Int(1_000_000_000_000_000), Value::Int(-1_000_000_000_000_000)];
        values.extend([
            Value::Text("-170141183460469231731687303715884105728".into()),
            Value::Text("170141183460469231731687303715884105727".into()),
            Value::Text("340282366920938463463374607431768211455".into()),
        ]);
        for text in corpus["integers"].as_array().unwrap() {
            let value: i64 = text.as_str().unwrap().parse().unwrap();
            if value.unsigned_abs() > 999_999_999_999_999 {
                values.push(Value::Int(value));
            }
        }
        for text in corpus["decimals"].as_array().unwrap() {
            values.push(Value::Decimal(text.as_str().unwrap().parse().unwrap()));
        }
        let (sheet, strings) = workbook_parts(&values);
        for (index, value) in values.iter().enumerate() {
            let row = index + 2;
            let text = value_to_text(value).unwrap();
            let string_index = strings
                .split("<si>")
                .skip(1)
                .position(|entry| entry.starts_with(&format!("<t>{text}</t>")))
                .unwrap();
            assert!(
                sheet.contains(&format!("<c r=\"A{row}\" t=\"s\"><v>{string_index}</v></c>")),
                "{value:?}: {sheet}"
            );
        }
    }

    #[test]
    fn value_contract_workbook_keeps_text_null_labels_as_strings_and_sql_null_blank() {
        let (sheet, strings) = workbook_parts(&[
            Value::Text("NULL".into()),
            Value::Text("東京".into()),
            Value::Text("<tag>&amp;".into()),
            Value::Text("=1+1".into()),
            Value::Null,
        ]);

        for row in 2..=5 {
            assert!(sheet.contains(&format!("<c r=\"A{row}\" t=\"s\">")), "{sheet}");
        }
        assert!(strings.contains("<t>NULL</t>"), "{strings}");
        assert!(strings.contains("<t>東京</t>"), "{strings}");
        assert!(strings.contains("<t>&lt;tag&gt;&amp;amp;</t>"), "{strings}");
        assert!(strings.contains("<t>=1+1</t>"), "{strings}");
        assert!(!sheet.contains("r=\"A6\""), "{sheet}");
        assert!(!sheet.contains("<f>"), "{sheet}");
    }

    #[test]
    fn value_contract_workbook_preserves_temporal_precision_and_timezone_as_text() {
        let cases = [
            (Value::Date("1899-12-31".parse().unwrap()), "1899-12-31"),
            (Value::Date("0000-01-01".parse().unwrap()), "0000-01-01"),
            (Value::Date("+10000-01-01".parse().unwrap()), "+10000-01-01"),
            (Value::Time("12:34:56.123456789".parse().unwrap()), "12:34:56.123456789"),
            (
                Value::DateTime("2026-09-27T12:34:56.123456789".parse().unwrap()),
                "2026-09-27 12:34:56.123456789",
            ),
            (
                Value::DateTime("0000-01-01T00:00:00".parse().unwrap()),
                "0000-01-01 00:00:00",
            ),
            (
                Value::TimestampTz("2024-11-03T05:30:00Z".parse().unwrap()),
                "2024-11-03T05:30:00+00:00",
            ),
            (
                Value::TimestampTz("2024-11-03T06:30:00Z".parse().unwrap()),
                "2024-11-03T06:30:00+00:00",
            ),
            (
                Value::TimestampTz("2026-09-27T12:34:56.123456789+05:30".parse().unwrap()),
                "2026-09-27T07:04:56.123456789+00:00",
            ),
        ];
        for (value, expected) in cases {
            let (sheet, strings) = workbook_parts(std::slice::from_ref(&value));
            assert!(strings.contains(&format!("<t>{expected}</t>")), "{value:?}: {strings}");
            assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{value:?}: {sheet}");
        }
    }

    #[test]
    fn value_contract_workbook_keeps_supported_whole_second_temporals_numeric() {
        for (value, serial) in [
            (Value::Date("1900-01-01".parse().unwrap()), "1"),
            (Value::Date("9999-12-31".parse().unwrap()), "2958465"),
            (Value::Time("12:00:00".parse().unwrap()), "0.5"),
            (Value::DateTime("1900-01-01T12:00:00".parse().unwrap()), "1.5"),
            (Value::DateTime("9999-12-31T00:00:00".parse().unwrap()), "2958465"),
        ] {
            let (sheet, _) = workbook_parts(std::slice::from_ref(&value));
            assert!(sheet.contains("<c r=\"A2\" s=\""), "{value:?}: {sheet}");
            assert!(sheet.contains(&format!("<v>{serial}</v></c>")), "{value:?}: {sheet}");
        }
    }

    #[test]
    fn value_contract_workbook_float_specials_stay_distinct_from_null() {
        let (sheet, strings) = workbook_parts(&[
            Value::Float(1.25),
            Value::Float(f64::NAN),
            Value::Float(f64::INFINITY),
            Value::Float(f64::NEG_INFINITY),
            Value::Null,
        ]);
        assert!(sheet.contains("<c r=\"A2\"><v>1.25</v></c>"), "{sheet}");
        for text in ["NaN", "inf", "-inf"] {
            assert!(strings.contains(&format!("<t>{text}</t>")), "{strings}");
        }
        for row in [3, 4, 5] {
            assert!(sheet.contains(&format!("<c r=\"A{row}\" t=\"s\">")), "{sheet}");
        }
        assert!(!sheet.contains("r=\"A6\""), "{sheet}");
    }

    #[test]
    fn value_contract_workbook_keeps_excel_precision_risk_floats_as_text() {
        let values = [
            -0.0,
            f64::from_bits(1),
            f64::from_bits(0x3ff0_0000_0000_0001),
            1.234_567_890_123_456,
            1.234_567_890_123_456_7,
            1.0e-320,
            f64::MAX,
        ];
        let (sheet, strings) = workbook_parts(&values.map(Value::Float));

        for (index, value) in values.into_iter().enumerate() {
            let row = index + 2;
            assert!(sheet.contains(&format!("<c r=\"A{row}\" t=\"s\">")), "{sheet}");
            assert!(strings.contains(&format!("<t>{value}</t>")), "{strings}");
        }
    }

    #[test]
    fn value_contract_workbook_keeps_excel_safe_floats_numeric() {
        let values = [
            0.0,
            123.5,
            2.2251e-308,
            1.0e-100,
            1.234_567_890_123_45,
            999_999_999_999_999.0,
            9.99999999999999e307,
        ];
        let (sheet, _) = workbook_parts(&values.map(Value::Float));

        for (index, expected) in values.into_iter().enumerate() {
            let row = index + 2;
            assert!(sheet.contains(&format!("<c r=\"A{row}\"><v>")), "{expected}: {sheet}");
        }
    }

    #[test]
    fn value_contract_workbook_preserves_nested_extended_json_as_exact_text() {
        let value = Value::Json(serde_json::json!({
            "decimal": {"$numberDecimal": "9.999999999999999999999999999999999E+6144"},
            "binary": {"$binary": {"base64": "AQID", "subType": "80"}},
            "date": {"$date": {"$numberLong": "9223372036854775807"}},
        }));
        let expected = value_to_text(&value).unwrap();
        let (sheet, strings) = workbook_parts(&[value]);

        assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
        assert!(strings.contains(&format!("<t>{expected}</t>")), "{strings}");
        assert!(strings.contains("$numberDecimal"), "{strings}");
        assert!(strings.contains("$numberLong"), "{strings}");
        assert!(strings.contains("\"subType\":\"80\""), "{strings}");
    }

    #[test]
    fn value_contract_workbook_keeps_small_integers_numeric() {
        let (sheet, _) = workbook_parts(&[Value::Int(999_999_999_999_999), Value::Int(-7), Value::Int(0)]);
        assert!(sheet.contains("<c r=\"A2\"><v>999999999999999</v></c>"), "{sheet}");
        assert!(sheet.contains("<c r=\"A3\"><v>-7</v></c>"), "{sheet}");
        assert!(sheet.contains("<c r=\"A4\"><v>0</v></c>"), "{sheet}");
    }

    #[test]
    fn a_result_over_the_sheet_limit_is_refused_with_the_limit_in_the_message() {
        let Err(error) = XlsxWriter::new(MAX_WORKBOOK_ROWS + 1) else {
            panic!("a result over the limit must be refused");
        };
        assert!(
            matches!(
                error,
                ExportError::WorkbookTooLarge {
                    limit: MAX_WORKBOOK_ROWS,
                    rows
                } if rows == MAX_WORKBOOK_ROWS + 1
            ),
            "{error:?}"
        );
        assert!(error.to_string().contains("1048575"), "{error}");
    }

    #[test]
    fn value_contract_workbook_rejects_invalid_cell_coordinates_without_overflow() {
        assert_eq!(cell_column(16_383).unwrap(), 16_383);
        for index in [16_384, 65_535, usize::MAX] {
            assert!(
                matches!(cell_column(index), Err(ExportError::WorkbookColumnLimit { columns }) if columns == index.saturating_add(1))
            );
        }
        let mut writer = XlsxWriter::new(0).unwrap();
        writer.write_row(&mut Vec::new(), 1_048_574, &[Value::Int(1)]).unwrap();
        for index in [1_048_575, usize::MAX] {
            assert!(matches!(writer.write_row(&mut Vec::new(), index, &[Value::Int(1)]),
                Err(ExportError::WorkbookTooLarge { limit: 1_048_575, rows }) if rows == index.saturating_add(1)));
        }
    }

    #[test]
    fn a_result_at_the_sheet_limit_is_accepted() {
        assert!(XlsxWriter::new(MAX_WORKBOOK_ROWS).is_ok(), "the limit itself must fit");
    }

    #[test]
    fn a_workbook_is_written_as_a_zip_container_with_one_sheet() {
        let Ok(mut writer) = XlsxWriter::new(1) else {
            panic!("one row fits");
        };
        let mut output: Vec<u8> = Vec::new();
        writer.begin(&mut output, &[column("id"), column("when")]).unwrap();
        writer
            .write_row(
                &mut output,
                0,
                &[Value::Int(7), Value::Date("2026-09-19".parse().unwrap())],
            )
            .unwrap();
        writer.finish(&mut output).unwrap();

        assert_eq!(&output[..2], b"PK");
        assert!(output.len() > 1000, "{}", output.len());
    }
}
