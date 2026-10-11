use std::io::{self, Write};

use serde::{Deserialize, Serialize};

use super::error::ExportError;
use super::file::ResultWriter;
use super::value_to_text;
use crate::query::{ColumnInfo, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDelimiter {
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

impl CsvDelimiter {
    pub const ALL: [Self; 4] = [Self::Comma, Self::Semicolon, Self::Tab, Self::Pipe];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Comma => ",",
            Self::Semicolon => ";",
            Self::Tab => "\t",
            Self::Pipe => "|",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvQuote {
    Always,
    IfNeeded,
    Never,
}

impl CsvQuote {
    pub const ALL: [Self; 3] = [Self::Always, Self::IfNeeded, Self::Never];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvLineBreak {
    Lf,
    CrLf,
    Cr,
}

impl CsvLineBreak {
    pub const ALL: [Self; 3] = [Self::Lf, Self::CrLf, Self::Cr];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lf => "\n",
            Self::CrLf => "\r\n",
            Self::Cr => "\r",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDecimal {
    Period,
    Comma,
}

impl CsvDecimal {
    pub const ALL: [Self; 2] = [Self::Period, Self::Comma];
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CsvOptions {
    pub null_to_empty: bool,
    pub null_marker: Option<String>,
    pub line_break_to_space: bool,
    pub header_row: bool,
    pub sanitize_formulas: bool,
    /// Encode non-NULL cells with SQLite's storage-class tags when result
    /// metadata is unavailable. Enable only for SQLite result exports.
    pub preserve_sqlite_result_types: bool,
    pub delimiter: CsvDelimiter,
    pub quote: CsvQuote,
    pub line_break: CsvLineBreak,
    pub decimal: CsvDecimal,
}

impl Default for CsvOptions {
    fn default() -> Self {
        Self {
            null_to_empty: true,
            null_marker: None,
            line_break_to_space: false,
            header_row: true,
            sanitize_formulas: true,
            preserve_sqlite_result_types: false,
            delimiter: CsvDelimiter::Comma,
            quote: CsvQuote::IfNeeded,
            line_break: CsvLineBreak::Lf,
            decimal: CsvDecimal::Period,
        }
    }
}

pub fn render_csv(columns: &[ColumnInfo], rows: &[Vec<Value>], options: &CsvOptions) -> String {
    let mut output = String::new();
    if options.header_row {
        output.push_str(&csv_header_line(columns, options));
        output.push_str(options.line_break.as_str());
    }
    for row in rows {
        output.push_str(&csv_row_line_for_columns(row, columns, options));
        output.push_str(options.line_break.as_str());
    }
    output
}

pub fn unique_csv_null_marker(rows: &[Vec<Value>]) -> String {
    let mut marker = "\\N".to_string();
    while rows
        .iter()
        .flatten()
        .any(|value| value_to_text(value).as_deref() == Some(marker.as_str()))
    {
        marker.push('N');
    }
    marker
}

pub(crate) fn csv_header_line(columns: &[ColumnInfo], options: &CsvOptions) -> String {
    columns
        .iter()
        .map(|column| escape_csv_field(&column.name, options, false))
        .collect::<Vec<_>>()
        .join(options.delimiter.as_str())
}

pub(crate) fn csv_row_line(row: &[Value], options: &CsvOptions) -> String {
    csv_row_line_with_any_columns(row, &[], options)
}

fn csv_row_line_for_columns(row: &[Value], columns: &[ColumnInfo], options: &CsvOptions) -> String {
    let any_columns = columns
        .iter()
        .map(|column| {
            crate::sqlite_any_csv::is_any_type(&column.data_type)
                || (options.preserve_sqlite_result_types && crate::sqlite_any_csv::is_unknown_type(&column.data_type))
        })
        .collect::<Vec<_>>();
    csv_row_line_with_any_columns(row, &any_columns, options)
}

fn csv_row_line_with_any_columns(row: &[Value], any_columns: &[bool], options: &CsvOptions) -> String {
    row.iter()
        .enumerate()
        .map(|(index, value)| {
            if any_columns.get(index) == Some(&true)
                && let Some(encoded) = crate::sqlite_any_csv::encode(value)
            {
                return format_csv_cell(&Value::Text(encoded), options);
            }
            format_csv_cell(value, options)
        })
        .collect::<Vec<_>>()
        .join(options.delimiter.as_str())
}

pub fn render_tsv(columns: &[ColumnInfo], rows: &[Vec<Value>], with_headers: bool) -> String {
    let options = CsvOptions {
        header_row: with_headers,
        null_to_empty: false,
        null_marker: Some(unique_csv_null_marker(rows)),
        delimiter: CsvDelimiter::Tab,
        ..CsvOptions::default()
    };
    let mut lines = Vec::with_capacity(rows.len() + usize::from(with_headers));
    if with_headers {
        lines.push(csv_header_line(columns, &options));
    }
    for row in rows {
        lines.push(csv_row_line(row, &options));
    }
    lines.join("\n")
}

fn rfc4180_options(header_row: bool) -> CsvOptions {
    CsvOptions {
        header_row,
        sanitize_formulas: false,
        ..CsvOptions::default()
    }
}

/// Escape and write a CSV header line for `columns`.
pub fn write_csv_header(writer: &mut impl Write, columns: &[ColumnInfo]) -> io::Result<()> {
    let options = rfc4180_options(true);
    writeln!(writer, "{}", csv_header_line(columns, &options))
}

pub fn write_csv_header_with_options(
    writer: &mut impl Write,
    columns: &[ColumnInfo],
    options: &CsvOptions,
) -> io::Result<()> {
    writeln!(writer, "{}", csv_header_line(columns, options))
}

/// Escape and write one CSV data row.
pub fn write_csv_row(writer: &mut impl Write, row: &[Value]) -> io::Result<()> {
    let options = rfc4180_options(false);
    writeln!(writer, "{}", csv_row_line(row, &options))
}

pub fn write_csv_row_with_options(writer: &mut impl Write, row: &[Value], options: &CsvOptions) -> io::Result<()> {
    writeln!(writer, "{}", csv_row_line(row, options))
}

pub fn write_csv_row_with_columns_and_options(
    writer: &mut impl Write,
    columns: &[ColumnInfo],
    row: &[Value],
    options: &CsvOptions,
) -> io::Result<()> {
    writeln!(writer, "{}", csv_row_line_for_columns(row, columns, options))
}

fn is_plain_decimal(value: &str) -> bool {
    let unsigned = match value.strip_prefix(['+', '-']) {
        Some(value) => value,
        None => value,
    };
    let Some((integer, fraction)) = unsigned.split_once('.') else {
        return false;
    };
    !integer.is_empty()
        && !fraction.is_empty()
        && integer.chars().all(|character| character.is_ascii_digit())
        && fraction.chars().all(|character| character.is_ascii_digit())
}

pub(crate) fn quote_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn escape_csv_field(value: &str, options: &CsvOptions, had_line_breaks: bool) -> String {
    let mut value = value.to_string();
    let neutralized = options.sanitize_formulas && value.starts_with(['=', '+', '-', '@', '\t', '\r']);
    if neutralized {
        value.insert(0, '\'');
    }
    match options.quote {
        CsvQuote::Always => quote_field(&value),
        CsvQuote::Never => value,
        CsvQuote::IfNeeded => {
            if value.contains(options.delimiter.as_str())
                || value.contains(['"', '\n', '\r', '\t'])
                || had_line_breaks
                || neutralized
            {
                quote_field(&value)
            } else {
                value
            }
        }
    }
}

fn format_csv_cell(value: &Value, options: &CsvOptions) -> String {
    let mut options = options.clone();
    options.sanitize_formulas &= matches!(value, Value::Text(_));
    let options = &options;
    let Some(mut text) = value_to_text(value) else {
        if let Some(marker) = &options.null_marker {
            return escape_csv_field(marker, options, false);
        }
        if options.null_to_empty {
            return String::new();
        }
        return escape_csv_field("NULL", options, false);
    };
    if text.is_empty() && options.quote != CsvQuote::Never {
        return quote_field(&text);
    }
    let had_line_breaks = text.contains(['\n', '\r']);
    if options.line_break_to_space {
        text = text.replace("\r\n", " ").replace(['\r', '\n'], " ");
    }
    if options.decimal == CsvDecimal::Comma && is_plain_decimal(&text) {
        text = text.replace('.', ",");
    }
    escape_csv_field(&text, options, had_line_breaks)
}

pub(crate) struct CsvWriter {
    header: CsvOptions,
    rows: CsvOptions,
    any_columns: Vec<bool>,
}

impl CsvWriter {
    pub(crate) fn new(options: &CsvOptions) -> Self {
        Self {
            header: options.clone(),
            rows: CsvOptions {
                header_row: false,
                ..options.clone()
            },
            any_columns: Vec::new(),
        }
    }
}

impl ResultWriter for CsvWriter {
    fn begin(&mut self, output: &mut dyn Write, columns: &[ColumnInfo]) -> Result<(), ExportError> {
        self.any_columns = columns
            .iter()
            .map(|column| {
                crate::sqlite_any_csv::is_any_type(&column.data_type)
                    || (self.header.preserve_sqlite_result_types
                        && crate::sqlite_any_csv::is_unknown_type(&column.data_type))
            })
            .collect();
        if !self.header.header_row {
            return Ok(());
        }
        output.write_all(csv_header_line(columns, &self.header).as_bytes())?;
        output.write_all(self.header.line_break.as_str().as_bytes())?;
        Ok(())
    }

    fn write_row(&mut self, output: &mut dyn Write, _index: usize, row: &[Value]) -> Result<(), ExportError> {
        output.write_all(csv_row_line_with_any_columns(row, &self.any_columns, &self.rows).as_bytes())?;
        output.write_all(self.rows.line_break.as_str().as_bytes())?;
        Ok(())
    }

    fn finish(&mut self, _output: &mut dyn Write) -> Result<(), ExportError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::test_support::column;

    #[test]
    fn csv_header_and_row() {
        let cols = vec![column("a,b")];
        let mut buf = Vec::new();
        write_csv_header(&mut buf, &cols).unwrap();
        write_csv_row(&mut buf, &[Value::Text("hello".into())]).unwrap();
        let s = String::from_utf8(buf).unwrap();
        assert_eq!(s, "\"a,b\"\nhello\n");
    }

    #[test]
    fn rfc4180_csv_header_keeps_formula_like_column_names_unchanged() {
        let columns = vec![column("=expression"), column("+label")];
        let mut output = Vec::new();

        write_csv_header(&mut output, &columns).unwrap();

        assert_eq!(output, b"=expression,+label\n");
    }

    #[test]
    fn the_plain_csv_writers_keep_formula_text_and_render_null_as_an_empty_field() {
        let mut buf = Vec::new();
        write_csv_row(&mut buf, &[Value::Text("=SUM(A1)".into()), Value::Null]).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), "=SUM(A1),\n");
    }

    #[test]
    fn csv_writer_uses_explicit_null_marker_without_changing_empty_text() {
        let columns = vec![column("value")];
        let rows = vec![vec![Value::Null], vec![Value::Text(String::new())]];
        let options = CsvOptions {
            null_to_empty: false,
            null_marker: Some("\\N".into()),
            ..CsvOptions::default()
        };

        assert_eq!(render_csv(&columns, &rows, &options), "value\n\\N\n\"\"\n");
    }

    #[test]
    fn csv_null_marker_skips_values_already_in_the_result() {
        let rows = vec![vec![Value::Text("\\N".into())], vec![Value::Text("\\NN".into())]];

        assert_eq!(unique_csv_null_marker(&rows), "\\NNN");
    }

    #[test]
    fn sqlite_any_csv_render_and_column_aware_row_writer_use_type_tags() {
        let columns = [ColumnInfo {
            data_type: "ANY".into(),
            ..crate::export::test_support::column("value")
        }];
        let rows = vec![
            vec![Value::Int(42)],
            vec![Value::Float(1.5)],
            vec![Value::Text("bookie:sqlite-any:v1:integer:9".into())],
            vec![Value::Text(String::new())],
            vec![Value::Null],
            vec![Value::Bytes(vec![0, 255])],
        ];
        let options = CsvOptions {
            null_to_empty: false,
            null_marker: Some("\\N".into()),
            ..CsvOptions::default()
        };
        let rendered = render_csv(&columns, &rows, &options);
        let mut row_writer = Vec::new();
        write_csv_header_with_options(&mut row_writer, &columns, &options).unwrap();
        for row in &rows {
            write_csv_row_with_columns_and_options(&mut row_writer, &columns, row, &options).unwrap();
        }
        assert_eq!(String::from_utf8(row_writer).unwrap(), rendered);
        assert!(rendered.contains("bookie:sqlite-any:v1:integer:42"));
        assert!(rendered.contains("bookie:sqlite-any:v1:blob:00ff"));
        assert!(rendered.contains("bookie:sqlite-any:v1:text:bookie:sqlite-any:v1:integer:9"));
    }

    #[test]
    fn sqlite_result_type_tags_are_opt_in_for_fallback_metadata() {
        let columns = [ColumnInfo {
            data_type: "NULL".into(),
            ..crate::export::test_support::column("value")
        }];
        let rows = [vec![Value::Int(42)]];

        assert_eq!(render_csv(&columns, &rows, &CsvOptions::default()), "value\n42\n");
        assert_eq!(
            render_csv(
                &columns,
                &rows,
                &CsvOptions {
                    preserve_sqlite_result_types: true,
                    ..CsvOptions::default()
                }
            ),
            "value\nbookie:sqlite-any:v1:integer:42\n"
        );
    }

    #[test]
    fn value_contract_csv_keeps_empty_text_distinct_from_null() {
        let columns = vec![column("value")];
        let rows = vec![vec![Value::Null], vec![Value::Text(String::new())]];
        assert_eq!(render_csv(&columns, &rows, &CsvOptions::default()), "value\n\n\"\"\n");
        let always = CsvOptions {
            quote: CsvQuote::Always,
            ..CsvOptions::default()
        };
        assert_eq!(render_csv(&columns, &rows, &always), "\"value\"\n\n\"\"\n");
        let mut buf = Vec::new();
        write_csv_row(&mut buf, &[Value::Null, Value::Text(String::new())]).unwrap();
        assert_eq!(String::from_utf8(buf).unwrap(), ",\"\"\n");
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_bool_uuid_and_json() {
        let mut flag = column("flag");
        flag.data_type = "BOOLEAN".into();
        let mut id = column("id");
        id.data_type = "UUID".into();
        let mut payload = column("payload");
        payload.data_type = "JSONB".into();
        let columns = [flag, id, payload];
        let rows = vec![
            vec![
                Value::Bool(true),
                Value::Uuid("550e8400-e29b-41d4-a716-446655440000".parse().unwrap()),
                Value::Json(serde_json::json!({"ok": true, "n": 1})),
            ],
            vec![
                Value::Bool(false),
                Value::Uuid("00000000-0000-4000-8000-000000000000".parse().unwrap()),
                Value::Json(serde_json::json!([null, "a,b", {"x": 2}])),
            ],
            vec![Value::Null, Value::Null, Value::Null],
        ];
        let csv = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(
            csv,
            concat!(
                "flag,id,payload\n",
                "true,550e8400-e29b-41d4-a716-446655440000,\"{\"\"ok\"\":true,\"\"n\"\":1}\"\n",
                "false,00000000-0000-4000-8000-000000000000,\"[null,\"\"a,b\"\",{\"\"x\"\":2}]\"\n",
                ",,\n",
            )
        );

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let restored: Vec<Vec<Value>> = sheet
            .rows
            .iter()
            .enumerate()
            .map(|(index, row)| {
                crate::import::row_to_values(row, &[Some(0), Some(1), Some(2)], &columns, &options, index + 2).unwrap()
            })
            .collect();
        assert_eq!(restored, rows);
    }

    #[test]
    fn value_contract_csv_binary_round_trip_preserves_null_empty_and_every_byte() {
        let mut binary_column = column("payload");
        binary_column.data_type = "BYTEA".into();
        let columns = [column("id"), binary_column];
        let rows = vec![
            vec![Value::Text("null".into()), Value::Null],
            vec![Value::Text("empty".into()), Value::Bytes(vec![])],
            vec![Value::Text("binary".into()), Value::Bytes((0..=255).collect())],
        ];
        for delimiter in CsvDelimiter::ALL {
            let csv = render_csv(
                &columns,
                &rows,
                &CsvOptions {
                    delimiter,
                    ..CsvOptions::default()
                },
            );
            let options = crate::import::CsvImportOptions {
                delimiter,
                ..Default::default()
            };
            let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
            let restored: Vec<Vec<Value>> = sheet
                .rows
                .iter()
                .enumerate()
                .map(|(index, row)| {
                    crate::import::row_to_values(row, &[Some(0), Some(1)], &columns, &options, index + 2).unwrap()
                })
                .collect();
            assert_eq!(restored, rows);
        }
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_signed_integer_boundaries() {
        let mut value_column = column("value");
        value_column.data_type = "BIGINT".into();
        let columns = [value_column];
        let expected = [i64::MIN, 9_007_199_254_740_993, i64::MAX];
        let rows: Vec<Vec<Value>> = expected.iter().map(|value| vec![Value::Int(*value)]).collect();
        let csv = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(
            csv,
            "value\n-9223372036854775808\n9007199254740993\n9223372036854775807\n"
        );

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let imported: Vec<Value> = sheet
            .rows
            .iter()
            .map(|row| crate::import::row_to_values(row, &[Some(0)], &columns, &options, 2).unwrap()[0].clone())
            .collect();
        assert_eq!(imported, expected.into_iter().map(Value::Int).collect::<Vec<_>>());
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_decimal_trailing_zeroes() {
        let mut value_column = column("value");
        value_column.data_type = "DECIMAL(10,4)".into();
        let columns = [value_column];
        let expected: rust_decimal::Decimal = "12.3000".parse().unwrap();
        let csv = render_csv(&columns, &[vec![Value::Decimal(expected)]], &CsvOptions::default());
        assert_eq!(csv, "value\n12.3000\n");

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let imported = crate::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
        let Value::Decimal(actual) = imported[0] else {
            panic!("CSV import did not produce a decimal: {imported:?}");
        };
        assert_eq!(actual.to_string(), "12.3000");
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_negative_zero_bits() {
        let mut value_column = column("value");
        value_column.data_type = "DOUBLE PRECISION".into();
        let columns = [value_column];
        let expected = -0.0f64;
        let csv = render_csv(&columns, &[vec![Value::Float(expected)]], &CsvOptions::default());
        assert_eq!(csv, "value\n-0\n");

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let values = crate::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
        let Value::Float(actual) = values[0] else {
            panic!("CSV import did not produce a float: {values:?}");
        };
        assert_eq!(actual.to_bits(), expected.to_bits());
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_smallest_subnormal_bits() {
        let mut value_column = column("value");
        value_column.data_type = "DOUBLE PRECISION".into();
        let columns = [value_column];
        let expected = f64::from_bits(1);
        let csv = render_csv(&columns, &[vec![Value::Float(expected)]], &CsvOptions::default());

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let values = crate::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
        let Value::Float(actual) = values[0] else {
            panic!("CSV import did not produce a float: {values:?}");
        };
        assert_eq!(actual.to_bits(), expected.to_bits());
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_largest_finite_float_bits() {
        let mut value_column = column("value");
        value_column.data_type = "DOUBLE PRECISION".into();
        let columns = [value_column];
        let expected = f64::MAX;
        let csv = render_csv(&columns, &[vec![Value::Float(expected)]], &CsvOptions::default());

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let values = crate::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
        let Value::Float(actual) = values[0] else {
            panic!("CSV import did not produce a float: {values:?}");
        };
        assert_eq!(actual.to_bits(), expected.to_bits());
    }

    #[test]
    fn value_contract_csv_and_json_round_trip_seeded_finite_float_bits() {
        let mut value_column = column("value");
        value_column.data_type = "DOUBLE PRECISION".into();
        let columns = [value_column];

        // Fixed xorshift seed gives reproducible raw finite-bit samples,
        // including subnormals, without an extra property-test dependency.
        let mut state = 0x6a09_e667_f3bc_c909_u64;
        let mut expected = vec![
            f64::from_bits(0x3fef_ffff_ffff_ffff),
            f64::from_bits(0x3ff0_0000_0000_0001),
            f64::from_bits(0x0000_0000_0000_0002),
            f64::from_bits(0x0010_0000_0000_0001),
            f64::from_bits(0x7fef_ffff_ffff_fffe),
            f64::from_bits(0xffef_ffff_ffff_fffe),
        ];
        for _ in 0..65_536 {
            loop {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                if ((state >> 52) & 0x7ff) != 0x7ff {
                    expected.push(f64::from_bits(state));
                    break;
                }
            }
        }
        let mantissas = [0, 1, 1 << 51, (1 << 52) - 2, (1 << 52) - 1];
        for sign in [0, 1_u64 << 63] {
            for exponent in 0..0x7ff_u64 {
                for mantissa in mantissas {
                    expected.push(f64::from_bits(sign | (exponent << 52) | mantissa));
                }
            }
        }
        assert_eq!(expected.len(), 86_012);
        assert!(expected.iter().all(|value| value.is_finite()));
        let rows = expected
            .iter()
            .map(|value| vec![Value::Float(*value)])
            .collect::<Vec<_>>();

        let csv = render_csv(&columns, &rows, &CsvOptions::default());
        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let imported = sheet
            .rows
            .iter()
            .map(|row| crate::import::row_to_values(row, &[Some(0)], &columns, &options, 2).unwrap()[0].clone())
            .collect::<Vec<_>>();
        for (expected, actual) in expected.iter().zip(imported) {
            let Value::Float(actual) = actual else {
                panic!("CSV changed a finite float's value type: {actual:?}");
            };
            assert_eq!(actual.to_bits(), expected.to_bits());
        }

        let json: serde_json::Value = serde_json::from_str(&crate::export::render_json(&columns, &rows)).unwrap();
        for (expected, row) in expected.iter().zip(json.as_array().unwrap()) {
            assert_eq!(row["value"].as_f64().unwrap().to_bits(), expected.to_bits());
        }
    }

    #[test]
    fn value_contract_csv_round_trip_preserves_timestamptz_nanoseconds() {
        let mut value_column = column("value");
        value_column.data_type = "TIMESTAMP WITH TIME ZONE".into();
        let columns = [value_column];
        let expected: Value = Value::TimestampTz("2026-09-27T12:34:56.123456789+05:30".parse().unwrap());
        let csv = render_csv(&columns, &[vec![expected.clone()]], &CsvOptions::default());
        assert_eq!(csv, "value\n2026-09-27T07:04:56.123456789+00:00\n");

        let json: serde_json::Value =
            serde_json::from_str(&crate::export::render_json(&columns, &[vec![expected.clone()]])).unwrap();
        assert_eq!(json[0]["value"], "2026-09-27T07:04:56.123456789+00:00");

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let values = crate::import::row_to_values(&sheet.rows[0], &[Some(0)], &columns, &options, 2).unwrap();
        assert_eq!(values, vec![expected]);
    }

    #[test]
    fn value_contract_csv_round_trip_keeps_nonfinite_floats_distinct_from_null() {
        let mut value_column = column("value");
        value_column.data_type = "DOUBLE PRECISION".into();
        let columns = [value_column, column("row_tag")];
        let rows = [
            vec![Value::Float(f64::NAN), Value::Text("nan".into())],
            vec![Value::Float(f64::INFINITY), Value::Text("pos".into())],
            vec![Value::Null, Value::Text("null".into())],
            vec![Value::Float(f64::NEG_INFINITY), Value::Text("neg".into())],
        ];
        let csv = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(csv, "value,row_tag\nNaN,nan\ninf,pos\n,null\n-inf,neg\n");

        let options = crate::import::CsvImportOptions::default();
        let sheet = crate::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let imported: Vec<Value> = sheet
            .rows
            .iter()
            .map(|row| {
                crate::import::row_to_values(row, &[Some(0), Some(1)], &columns, &options, 2).unwrap()[0].clone()
            })
            .collect();
        assert!(matches!(imported[0], Value::Float(value) if value.is_nan()));
        assert_eq!(imported[1], Value::Float(f64::INFINITY));
        assert_eq!(imported[2], Value::Null);
        assert_eq!(imported[3], Value::Float(f64::NEG_INFINITY));
    }

    #[test]
    fn csv_renderer_applies_export_options_without_losing_cell_content() {
        let columns = vec![column("formula"), column("amount")];
        let rows = vec![vec![
            Value::Text("=SUM(A1:A2)\r\nnext".into()),
            Value::Decimal("12.30".parse().unwrap()),
        ]];
        let options = CsvOptions {
            line_break_to_space: true,
            delimiter: CsvDelimiter::Semicolon,
            quote: CsvQuote::IfNeeded,
            line_break: CsvLineBreak::CrLf,
            decimal: CsvDecimal::Comma,
            ..CsvOptions::default()
        };

        assert_eq!(
            render_csv(&columns, &rows, &options),
            "formula;amount\r\n\"'=SUM(A1:A2) next\";12,30\r\n"
        );
    }

    #[test]
    fn csv_if_needed_quotes_each_structural_and_sanitization_trigger() {
        let columns = vec![
            column("delimiter"),
            column("quote"),
            column("line_break"),
            column("formula"),
        ];
        let rows = vec![vec![
            Value::Text("a,b".into()),
            Value::Text("a\"b".into()),
            Value::Text("line\nbreak".into()),
            Value::Text("=1+1".into()),
        ]];
        let options = CsvOptions {
            line_break_to_space: true,
            ..CsvOptions::default()
        };

        assert_eq!(
            render_csv(&columns, &rows, &options),
            "delimiter,quote,line_break,formula\n\"a,b\",\"a\"\"b\",\"line break\",\"'=1+1\"\n"
        );
    }

    #[test]
    fn csv_decimal_comma_only_rewrites_signed_plain_decimals() {
        let columns = vec![column("value")];
        let values = ["+1.20", "-2.50", "3.40", "1e2", ".5", "5.", "x.5", "5.x"];
        let rows = values
            .iter()
            .map(|value| vec![Value::Text((*value).into())])
            .collect::<Vec<_>>();
        let options = CsvOptions {
            delimiter: CsvDelimiter::Semicolon,
            decimal: CsvDecimal::Comma,
            sanitize_formulas: false,
            ..CsvOptions::default()
        };

        assert_eq!(
            render_csv(&columns, &rows, &options),
            "value\n+1,20\n-2,50\n3,40\n1e2\n.5\n5.\nx.5\n5.x\n"
        );
    }

    #[test]
    fn tsv_renderer_quotes_structural_characters_and_represents_nulls() {
        let columns = vec![column("a\tb"), column("value")];
        let rows = vec![vec![Value::Text("one\ntwo\"three".into()), Value::Null]];

        assert_eq!(
            render_tsv(&columns, &rows, true),
            "\"a\tb\"\tvalue\n\"one\ntwo\"\"three\"\t\\N"
        );
    }

    #[test]
    fn tsv_renderer_keeps_null_empty_marker_and_formula_text_distinct() {
        let columns = vec![column("status")];
        let rows = vec![
            vec![Value::Text("NULL".into())],
            vec![Value::Text(String::new())],
            vec![Value::Null],
            vec![Value::Text("\\N".into())],
            vec![Value::Text("\\NN".into())],
            vec![Value::Text("=1+1".into())],
        ];

        assert_eq!(
            render_tsv(&columns, &rows, false),
            "NULL\n\"\"\n\\NNN\n\\N\n\\NN\n\"'=1+1\""
        );
    }
}
