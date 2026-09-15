use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::column::ResultColumn;
use crate::value::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDelimiter {
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

impl CsvDelimiter {
    pub const ALL: [CsvDelimiter; 4] = [
        CsvDelimiter::Comma,
        CsvDelimiter::Semicolon,
        CsvDelimiter::Tab,
        CsvDelimiter::Pipe,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvQuote {
    Always,
    IfNeeded,
    Never,
}

impl CsvQuote {
    pub const ALL: [CsvQuote; 3] = [CsvQuote::Always, CsvQuote::IfNeeded, CsvQuote::Never];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvLineBreak {
    Lf,
    CrLf,
    Cr,
}

impl CsvLineBreak {
    pub const ALL: [CsvLineBreak; 3] = [CsvLineBreak::Lf, CsvLineBreak::CrLf, CsvLineBreak::Cr];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDecimal {
    Period,
    Comma,
}

impl CsvDecimal {
    pub const ALL: [CsvDecimal; 2] = [CsvDecimal::Period, CsvDecimal::Comma];
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CsvOptions {
    pub null_to_empty: bool,
    pub line_break_to_space: bool,
    pub header_row: bool,
    pub sanitize_formulas: bool,
    pub delimiter: CsvDelimiter,
    pub quote: CsvQuote,
    pub line_break: CsvLineBreak,
    pub decimal: CsvDecimal,
}

impl Default for CsvOptions {
    fn default() -> Self {
        CsvOptions {
            null_to_empty: true,
            line_break_to_space: false,
            header_row: true,
            sanitize_formulas: true,
            delimiter: CsvDelimiter::Comma,
            quote: CsvQuote::IfNeeded,
            line_break: CsvLineBreak::Lf,
            decimal: CsvDecimal::Period,
        }
    }
}

/// Full text of a value for export. Never truncates. `None` for Null.
pub fn value_to_text(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::Bool(b) => Some(if *b { "true".to_string() } else { "false".to_string() }),
        Value::Int(i) => Some(i.to_string()),
        Value::UInt(i) => Some(i.to_string()),
        Value::WideInt(i) => Some(i.to_string()),
        // Shortest round-trip form, so the text parses back to the
        // same bits. The non-finite ones have no numeric spelling.
        Value::Float32(f) => Some(float_text(
            f64::from(*f),
            f.is_nan(),
            f.is_infinite(),
            f.is_sign_negative(),
        )),
        Value::Float64(f) => Some(float_text(*f, f.is_nan(), f.is_infinite(), f.is_sign_negative())),
        // Full scale: trimming a trailing zero loses the precision
        // the column declared.
        Value::Decimal(d) => Some(d.to_string()),
        Value::Text(s) => Some(s.clone()),
        Value::Bytes(b) => Some(format!("0x{}", crate::hex::encode_lower(b))),
        Value::Uuid(u) => Some(u.to_string()),
        Value::Json(j) => Some(j.as_str().to_owned()),
        Value::Date(d) => temporal_text(d, |date| date.format("%Y-%m-%d").to_string()),
        // The fraction is kept as it came, never rounded to seconds.
        Value::Time(t) => Some(t.format(None)),
        Value::TimeTz(t) => Some(format!("{}{}", t.time.format(None), offset_text(t.offset))),
        Value::Timestamp(t) => temporal_text(t, |stamp| stamp.format("%Y-%m-%d %H:%M:%S%.f").to_string()),
        // The original offset, not UTC: the row said what zone it was
        // written in and the export says the same.
        Value::TimestampTz(t) => temporal_text(t, |stamp| {
            stamp.to_datetime().format("%Y-%m-%d %H:%M:%S%.f%:z").to_string()
        }),
        Value::Interval(i) => Some(i.to_string()),
        Value::Bits(b) => Some(b.to_string()),
        Value::Array(values) => Some(array_text(values)),
        Value::Other(other) => Some(other.text.clone()),
        // The driver could not read it, so there is no text to write.
        // The caller reports the cell rather than inventing one.
        Value::Undecodable(_) => None,
    }
}

fn float_text(value: f64, is_nan: bool, is_infinite: bool, is_negative: bool) -> String {
    if is_nan {
        return "NaN".to_owned();
    }
    if is_infinite {
        return if is_negative { "-Infinity" } else { "Infinity" }.to_owned();
    }
    value.to_string()
}

/// An infinite date or timestamp has a keyword rather than a number.
fn temporal_text<T>(value: &crate::value::Temporal<T>, finite: impl Fn(&T) -> String) -> Option<String> {
    match value {
        crate::value::Temporal::Finite(inner) => Some(finite(inner)),
        crate::value::Temporal::Infinity => Some("infinity".to_owned()),
        crate::value::Temporal::NegInfinity => Some("-infinity".to_owned()),
    }
}

fn offset_text(offset: chrono::FixedOffset) -> String {
    let total = offset.local_minus_utc();
    let sign = if total < 0 { '-' } else { '+' };
    let minutes = total.abs() / 60;
    format!("{sign}{:02}:{:02}", minutes / 60, minutes % 60)
}

/// An array as JSON array text, which is the one spelling every engine
/// reads back.
fn array_text(values: &[Value]) -> String {
    let parts: Vec<String> = values
        .iter()
        .map(|value| match value_to_text(value) {
            Some(text) => serde_json::Value::String(text).to_string(),
            None => "null".to_owned(),
        })
        .collect();
    format!("[{}]", parts.join(","))
}

fn is_plain_decimal(s: &str) -> bool {
    let unsigned = s.strip_prefix(['+', '-']).unwrap_or(s);
    let Some((int_part, frac_part)) = unsigned.split_once('.') else {
        return false;
    };
    !int_part.is_empty()
        && !frac_part.is_empty()
        && int_part.chars().all(|c| c.is_ascii_digit())
        && frac_part.chars().all(|c| c.is_ascii_digit())
}

/// Every leading character a spreadsheet may read as the start of a
/// formula: the four ASCII operators, the whitespace Excel strips before
/// parsing (so `\t=cmd|'/C calc'!A0` reaches the formula engine as
/// `=cmd|…` would), and the full-width forms of the operators.
pub const FORMULA_LEADS: [char; 11] = [
    '=', '+', '-', '@', '\t', '\r', '\n', '\u{FF1D}', '\u{FF0B}', '\u{FF0D}', '\u{FF20}',
];

fn is_plain_number(s: &str) -> bool {
    let bytes = s.as_bytes();
    let mut i = usize::from(matches!(bytes.first(), Some(b'+' | b'-')));
    let int_start = i;
    while bytes.get(i).is_some_and(u8::is_ascii_digit) {
        i += 1;
    }
    let int_digits = i - int_start;
    let mut frac_digits = 0;
    if bytes.get(i) == Some(&b'.') {
        i += 1;
        let frac_start = i;
        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        frac_digits = i - frac_start;
    }
    if int_digits == 0 && frac_digits == 0 {
        return false;
    }
    if matches!(bytes.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(bytes.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let exp_start = i;
        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        if i == exp_start {
            return false;
        }
    }
    i == bytes.len()
}

#[derive(Debug, Error)]
pub enum EncodeError {
    #[error("CSV encoding failed: {0}")]
    Csv(#[from] csv::Error),

    #[error("CSV output could not be flushed: {0}")]
    Flush(#[from] std::io::Error),

    #[error("CSV output is not valid UTF-8: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
}

/// A neutralised cell keeps its leading apostrophe as data only when the
/// field is quoted, so sanitising quotes every field.
pub fn csv_writer_builder(opts: &CsvOptions) -> csv::WriterBuilder {
    let delimiter = match opts.delimiter {
        CsvDelimiter::Comma => b',',
        CsvDelimiter::Semicolon => b';',
        CsvDelimiter::Tab => b'\t',
        CsvDelimiter::Pipe => b'|',
    };
    let terminator = match opts.line_break {
        CsvLineBreak::Lf => csv::Terminator::Any(b'\n'),
        CsvLineBreak::CrLf => csv::Terminator::CRLF,
        CsvLineBreak::Cr => csv::Terminator::Any(b'\r'),
    };
    let quote_style = match opts.quote {
        _ if opts.sanitize_formulas => csv::QuoteStyle::Always,
        CsvQuote::Always => csv::QuoteStyle::Always,
        CsvQuote::IfNeeded => csv::QuoteStyle::Necessary,
        CsvQuote::Never => csv::QuoteStyle::Never,
    };
    let mut builder = csv::WriterBuilder::new();
    builder
        .delimiter(delimiter)
        .terminator(terminator)
        .quote_style(quote_style);
    builder
}

/// A tab, a line break or a quote inside a value would move the following
/// text into the next column or the next row, so such a value is quoted
/// and its own quotes doubled. That is what a spreadsheet puts on the
/// clipboard for a multi-line cell, and what Calc and Excel parse back on
/// paste.
pub fn tsv_writer_builder() -> csv::WriterBuilder {
    let mut builder = csv::WriterBuilder::new();
    builder
        .delimiter(b'\t')
        .terminator(csv::Terminator::Any(b'\n'))
        .quote_style(csv::QuoteStyle::Necessary);
    builder
}

/// Only free text can smuggle a formula into a spreadsheet. A typed
/// number, date or UUID, and text that is itself a plain number, is data
/// the spreadsheet already reads correctly, and prefixing it would turn
/// `-5` into the string `'-5`.
pub fn neutralise_formula(value: &Value, text: String, is_header: bool) -> String {
    if is_header || matches!(value, Value::Text(_) | Value::Json(_)) {
        neutralise_text(text)
    } else {
        text
    }
}

fn neutralise_text(text: String) -> String {
    if text.starts_with(FORMULA_LEADS) && !is_plain_number(&text) {
        format!("'{text}")
    } else {
        text
    }
}

fn collapse_line_breaks(text: String, opts: &CsvOptions) -> String {
    if opts.line_break_to_space {
        text.replace("\r\n", " ").replace(['\r', '\n'], " ")
    } else {
        text
    }
}

fn csv_cell(value: &Value, opts: &CsvOptions) -> String {
    let Some(text) = value_to_text(value) else {
        return if opts.null_to_empty {
            String::new()
        } else {
            "NULL".to_string()
        };
    };
    let mut text = collapse_line_breaks(text, opts);
    let is_numeric = matches!(value, Value::Float32(_) | Value::Float64(_) | Value::Decimal(_));
    if opts.decimal == CsvDecimal::Comma && is_numeric && is_plain_decimal(&text) {
        text = text.replace('.', ",");
    }
    if opts.sanitize_formulas {
        neutralise_formula(value, text, false)
    } else {
        text
    }
}

fn csv_header(name: &str, opts: &CsvOptions) -> String {
    if opts.sanitize_formulas {
        neutralise_formula(&Value::Null, name.to_string(), true)
    } else {
        name.to_string()
    }
}

fn csv_text_field(text: &str, opts: &CsvOptions) -> String {
    let text = collapse_line_breaks(text.to_string(), opts);
    if opts.sanitize_formulas {
        neutralise_text(text)
    } else {
        text
    }
}

fn finish(writer: csv::Writer<Vec<u8>>) -> Result<String, EncodeError> {
    let bytes = writer
        .into_inner()
        .map_err(|error| EncodeError::Flush(error.into_error()))?;
    Ok(String::from_utf8(bytes)?)
}

pub fn render_csv(columns: &[ResultColumn], rows: &[Vec<Value>], opts: &CsvOptions) -> Result<String, EncodeError> {
    let mut writer = csv_writer_builder(opts).from_writer(Vec::new());
    if opts.header_row {
        writer.write_record(columns.iter().map(|column| csv_header(&column.name, opts)))?;
    }
    for row in rows {
        writer.write_record(row.iter().map(|value| csv_cell(value, opts)))?;
    }
    finish(writer)
}

/// CSV for records whose fields are all free text, such as exported query
/// history.
pub fn render_text_csv(header: &[&str], records: &[Vec<String>], opts: &CsvOptions) -> Result<String, EncodeError> {
    let mut writer = csv_writer_builder(opts).from_writer(Vec::new());
    if opts.header_row {
        writer.write_record(header.iter().map(|name| csv_header(name, opts)))?;
    }
    for record in records {
        writer.write_record(record.iter().map(|field| csv_text_field(field, opts)))?;
    }
    finish(writer)
}

pub fn render_tsv(columns: &[ResultColumn], rows: &[Vec<Value>], with_headers: bool) -> Result<String, EncodeError> {
    let mut writer = tsv_writer_builder().from_writer(Vec::new());
    if with_headers {
        writer.write_record(columns.iter().map(|column| column.name.as_str()))?;
    }
    for row in rows {
        writer.write_record(
            row.iter()
                .map(|value| value_to_text(value).unwrap_or_else(|| "NULL".to_string())),
        )?;
    }
    finish(writer)
}

fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::Value::Bool(*b),
        Value::Int(i) => serde_json::Value::Number((*i).into()),
        Value::UInt(i) => serde_json::Value::Number((*i).into()),
        // Past what a JSON number holds, so a string keeps the digits
        // rather than a reader rounding them.
        Value::WideInt(i) => serde_json::Value::String(i.to_string()),
        Value::Float32(f) => finite_json_number(f64::from(*f)),
        Value::Float64(f) => finite_json_number(*f),
        Value::Decimal(d) => {
            let s = d.to_string();
            match s.parse::<serde_json::Number>() {
                Ok(n) => serde_json::Value::Number(n),
                Err(_) => serde_json::Value::String(s),
            }
        }
        // Already JSON: embedding it parsed keeps it a value rather
        // than a string of one.
        Value::Json(j) => serde_json::from_str(j.as_str()).unwrap_or(serde_json::Value::Null),
        Value::Array(values) => serde_json::Value::Array(values.iter().map(value_to_json).collect()),
        other => match value_to_text(other) {
            Some(s) => serde_json::Value::String(s),
            None => serde_json::Value::Null,
        },
    }
}

/// JSON has no NaN or Infinity, so those go out as strings rather than
/// as a null that reads like a missing value.
fn finite_json_number(value: f64) -> serde_json::Value {
    match serde_json::Number::from_f64(value) {
        Some(number) => serde_json::Value::Number(number),
        None => serde_json::Value::String(float_text(
            value,
            value.is_nan(),
            value.is_infinite(),
            value.is_sign_negative(),
        )),
    }
}

/// One JSON key per column, in column order. A join can return the
/// same column name twice (`SELECT a.id, b.id …`) and a JSON object
/// keyed by name alone would keep the last of them and drop the rest,
/// so a repeat is suffixed `_2`, `_3`, … until it is unique against
/// every name already taken, including the literal names of later
/// columns.
pub fn json_field_names(columns: &[ResultColumn]) -> Vec<String> {
    let mut reserved: HashSet<String> = columns.iter().map(|c| c.name.clone()).collect();
    let mut emitted: HashSet<String> = HashSet::with_capacity(columns.len());
    let mut names = Vec::with_capacity(columns.len());
    for col in columns {
        let mut name = col.name.clone();
        if !emitted.insert(name.clone()) {
            let mut suffix = 2;
            loop {
                let candidate = format!("{}_{suffix}", col.name);
                if !reserved.contains(&candidate) && emitted.insert(candidate.clone()) {
                    name = candidate;
                    break;
                }
                suffix += 1;
            }
            reserved.insert(name.clone());
        }
        names.push(name);
    }
    names
}

fn row_to_json_object(names: &[String], row: &[Value]) -> serde_json::Value {
    let mut map = serde_json::Map::with_capacity(names.len());
    for (i, name) in names.iter().enumerate() {
        let value = row.get(i).map(value_to_json).unwrap_or(serde_json::Value::Null);
        map.insert(name.clone(), value);
    }
    serde_json::Value::Object(map)
}

pub fn row_to_json(columns: &[ResultColumn], row: &[Value]) -> serde_json::Value {
    row_to_json_object(&json_field_names(columns), row)
}

pub fn render_json(columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
    let names = json_field_names(columns);
    let values: Vec<serde_json::Value> = rows.iter().map(|row| row_to_json_object(&names, row)).collect();
    serde_json::to_string_pretty(&values).unwrap_or_else(|_| "[]".to_string())
}

fn markdown_cell(value: &Value) -> String {
    let text = value_to_text(value).unwrap_or_else(|| "NULL".to_string());
    text.replace('|', "\\|")
        .replace("\r\n", "<br>")
        .replace(['\r', '\n'], "<br>")
}

pub fn render_markdown(columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
    let mut lines: Vec<String> = Vec::new();
    let header: Vec<&str> = columns.iter().map(|c| c.name.as_str()).collect();
    lines.push(format!("| {} |", header.join(" | ")));
    let separator: Vec<&str> = columns.iter().map(|_| "---").collect();
    lines.push(format!("| {} |", separator.join(" | ")));
    for row in rows {
        let cells: Vec<String> = row.iter().map(markdown_cell).collect();
        lines.push(format!("| {} |", cells.join(" | ")));
    }
    lines.join("\n")
}

fn in_clause_literal(v: &Value) -> Option<String> {
    match v {
        // NULL never matches an IN list and turns a NOT IN into a
        // list that matches nothing at all; a binary literal has a
        // different spelling on every engine. Both are reported to
        // the caller rather than written.
        Value::Null | Value::Bytes(_) => None,
        Value::Bool(b) => Some(if *b { "TRUE".to_string() } else { "FALSE".to_string() }),
        Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => value_to_text(v),
        other => value_to_text(other).map(|s| format!("'{}'", s.replace('\'', "''"))),
    }
}

/// The `(…)` list plus the count of values it could not carry. An
/// empty `sql` means every value was skipped: `()` is a syntax error
/// on every engine, so the caller reports it instead of putting it on
/// the clipboard.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct InClause {
    pub sql: String,
    pub skipped: usize,
}

pub fn render_in_clause(rows: &[Vec<Value>], col_index: usize) -> InClause {
    let values: Vec<&Value> = rows.iter().filter_map(|row| row.get(col_index)).collect();
    let literals: Vec<String> = values.iter().filter_map(|v| in_clause_literal(v)).collect();
    InClause {
        skipped: values.len() - literals.len(),
        sql: if literals.is_empty() {
            String::new()
        } else {
            format!("({})", literals.join(", "))
        },
    }
}

#[cfg(test)]
mod tests {
    use chrono::{NaiveDate, NaiveTime};
    use std::str::FromStr;
    use uuid::Uuid;

    use crate::column::{CatalogType, ColumnKind, ColumnType, ReadForm, SqlTypeExpr, TextKind};
    use crate::value::{JsonText, SqlTime, Temporal};

    use super::*;

    fn col(name: &str) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType::new(
                SqlTypeExpr::from_catalog_text("text"),
                ColumnKind::Text(TextKind::Variable),
                CatalogType::Unknown,
                true,
                ReadForm::Native,
            ),
        )
    }

    fn date(year: i32, month: u32, day: u32) -> Value {
        Value::Date(Temporal::Finite(
            NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
        ))
    }

    fn json(text: &str) -> Value {
        Value::Json(JsonText::parse(text.to_owned()).expect("valid json"))
    }

    fn cols(names: &[&str]) -> Vec<ResultColumn> {
        names.iter().map(|n| col(n)).collect()
    }

    #[test]
    fn value_to_text_covers_every_variant() {
        assert_eq!(value_to_text(&Value::Null), None);
        assert_eq!(value_to_text(&Value::Bool(true)), Some("true".to_string()));
        assert_eq!(value_to_text(&Value::Bool(false)), Some("false".to_string()));
        assert_eq!(value_to_text(&Value::Int(42)), Some("42".to_string()));
        assert_eq!(value_to_text(&Value::UInt(u64::MAX)), Some(u64::MAX.to_string()));
        assert_eq!(value_to_text(&Value::Float64(1.5)), Some("1.5".to_string()));
        assert_eq!(value_to_text(&Value::Text("hi".into())), Some("hi".to_string()));
        assert_eq!(
            value_to_text(&Value::Bytes(vec![0xde, 0xad])),
            Some("0xdead".to_string())
        );
        assert_eq!(value_to_text(&date(2024, 1, 2)), Some("2024-01-02".to_string()));
        assert_eq!(
            value_to_text(&Value::Time(SqlTime::from_time_of_day(
                NaiveTime::from_hms_opt(13, 5, 9).expect("a time")
            ))),
            Some("13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Timestamp(Temporal::Finite(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .expect("a date")
                    .and_hms_opt(13, 5, 9)
                    .expect("a time")
            ))),
            Some("2024-01-02 13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Decimal("12.30".parse().expect("a decimal"))),
            Some("12.30".to_string()),
            "the declared scale was trimmed"
        );
        let uuid = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").expect("a uuid");
        assert_eq!(value_to_text(&Value::Uuid(uuid)), Some(uuid.to_string()));
        assert_eq!(value_to_text(&json(r#"{"a":1}"#)), Some(r#"{"a":1}"#.to_string()));
    }

    #[test]
    fn value_to_text_keeps_fraction_offset_and_full_scale() {
        let time = SqlTime::new(false, 12, 0, 0, 123_456_000).expect("a time");
        assert_eq!(value_to_text(&Value::Time(time)), Some("12:00:00.123456".to_owned()));

        let stamp = chrono::DateTime::parse_from_rfc3339("2024-06-15T12:00:00+05:30").expect("a timestamp");
        assert_eq!(
            value_to_text(&Value::TimestampTz(Temporal::Finite(
                crate::value::OffsetTimestamp::from_datetime(stamp)
            ))),
            Some("2024-06-15 12:00:00+05:30".to_owned()),
            "the row's own offset was rewritten as UTC"
        );

        assert_eq!(
            value_to_text(&Value::Decimal("1.0000000000".parse().expect("a decimal"))),
            Some("1.0000000000".to_owned())
        );
    }

    #[test]
    fn value_to_text_names_the_non_finite_values() {
        assert_eq!(value_to_text(&Value::Float64(f64::NAN)), Some("NaN".to_owned()));
        assert_eq!(
            value_to_text(&Value::Float64(f64::NEG_INFINITY)),
            Some("-Infinity".to_owned())
        );
        assert_eq!(
            value_to_text(&Value::Date(Temporal::Infinity)),
            Some("infinity".to_owned())
        );
    }

    #[test]
    fn an_undecodable_value_has_no_text() {
        let undecodable = Value::Undecodable(Box::new(crate::value::UndecodedValue {
            type_name: "geography".to_owned(),
            reason: crate::value::UndecodableReason::UnsupportedType,
        }));

        assert_eq!(
            value_to_text(&undecodable),
            None,
            "a value the driver could not read was given a text form"
        );
    }

    #[test]
    fn json_non_finite_float_is_string() {
        let columns = cols(&["v"]);
        let rows = vec![vec![Value::Float64(f64::INFINITY)]];

        let out = render_json(&columns, &rows);

        assert!(out.contains("\"Infinity\""), "{out}");
    }

    fn plain() -> CsvOptions {
        CsvOptions {
            sanitize_formulas: false,
            ..Default::default()
        }
    }

    #[test]
    fn csv_defaults_quote_every_field_when_sanitising() {
        let columns = cols(&["id", "name"]);
        let rows = vec![vec![Value::Int(1), Value::Text("Alice".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"id\",\"name\"\n\"1\",\"Alice\"\n");
    }

    #[test]
    fn csv_if_needed_leaves_plain_fields_bare() {
        let columns = cols(&["id", "name"]);
        let rows = vec![vec![Value::Int(1), Value::Text("Alice".into())]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "id,name\n1,Alice\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_delimiter() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has,comma".into())]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "a\n\"has,comma\"\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_quote_char() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("say \"hi\"".into())]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "a\n\"say \"\"hi\"\"\"\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_line_break() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("line1\nline2".into())]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "a\n\"line1\nline2\"\n");
    }

    #[test]
    fn csv_line_break_to_space_leaves_nothing_to_quote() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("line1\r\nline2".into())]];
        let opts = CsvOptions {
            line_break_to_space: true,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "a\nline1 line2\n");
    }

    #[test]
    fn csv_quote_always_quotes_everything() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain".into())]];
        let opts = CsvOptions {
            quote: CsvQuote::Always,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "\"a\"\n\"plain\"\n");
    }

    #[test]
    fn csv_quote_never_quotes_nothing_even_with_delimiter() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has,comma".into())]];
        let opts = CsvOptions {
            quote: CsvQuote::Never,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "a\nhas,comma\n");
    }

    #[test]
    fn csv_sanitising_overrides_quote_never() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("=cmd".into())]];
        let opts = CsvOptions {
            quote: CsvQuote::Never,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "\"a\"\n\"'=cmd\"\n");
    }

    #[test]
    fn csv_sanitizes_formula_prefixes() {
        let columns = cols(&["a"]);
        for ch in ['=', '+', '-', '@'] {
            let rows = vec![vec![Value::Text(format!("{ch}cmd"))]];
            let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
            assert_eq!(out, format!("\"a\"\n\"'{ch}cmd\"\n"), "prefix {ch} should be sanitized");
        }
    }

    #[test]
    fn csv_sanitizes_formula_lead_hidden_behind_whitespace() {
        let columns = cols(&["a"]);
        for lead in ['\t', '\r', '\n'] {
            let rows = vec![vec![Value::Text(format!("{lead}=cmd|'/C calc'!A0"))]];
            let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
            let expected = format!("\"a\"\n\"'{lead}=cmd|'/C calc'!A0\"\n");
            assert_eq!(out, expected, "lead {lead:?} should be sanitized and quoted");
        }
    }

    #[test]
    fn csv_sanitizes_full_width_formula_leads() {
        let columns = cols(&["a"]);
        for lead in ['\u{FF1D}', '\u{FF0B}', '\u{FF0D}', '\u{FF20}'] {
            let rows = vec![vec![Value::Text(format!("{lead}SUM(A1)"))]];
            let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
            assert_eq!(
                out,
                format!("\"a\"\n\"'{lead}SUM(A1)\"\n"),
                "lead {lead:?} should be sanitized"
            );
        }
    }

    #[test]
    fn csv_leaves_formula_text_alone_when_sanitising_is_off() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("=SUM(A1)".into())]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "a\n=SUM(A1)\n");
    }

    #[test]
    fn csv_does_not_sanitize_non_formula_prefixes() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain text".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"a\"\n\"plain text\"\n");
    }

    #[test]
    fn csv_decimal_comma_only_for_plain_decimals() {
        let columns = cols(&["a"]);
        let opts = CsvOptions {
            decimal: CsvDecimal::Comma,
            delimiter: CsvDelimiter::Semicolon,
            ..plain()
        };
        let render = |value: Value| render_csv(&columns, &[vec![value]], &opts).unwrap();
        assert_eq!(render(Value::Float64(1.5)), "a\n1,5\n");
        assert_eq!(render(Value::Float64(-1.5)), "a\n-1,5\n");
        assert_eq!(
            render(Value::Decimal("12.30".parse().expect("a decimal"))),
            "a\n12,30\n"
        );
        assert_eq!(render(Value::Text("1.5".into())), "a\n1.5\n");
        assert_eq!(render(Value::Text("1e5".into())), "a\n1e5\n");
        assert_eq!(render(Value::Int(12)), "a\n12\n");
        assert_eq!(render(Value::Text("1.2.3".into())), "a\n1.2.3\n");
    }

    #[test]
    fn csv_keeps_negative_int() {
        let columns = cols(&["a"]);
        let out = render_csv(&columns, &[vec![Value::Int(-5)]], &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"a\"\n\"-5\"\n");
    }

    #[test]
    fn csv_keeps_negative_decimal() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Decimal("-12.30".parse().expect("a decimal"))]];
        let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"a\"\n\"-12.30\"\n");
    }

    #[test]
    fn csv_keeps_negative_float() {
        let columns = cols(&["a"]);
        let out = render_csv(&columns, &[vec![Value::Float64(-1.5)]], &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"a\"\n\"-1.5\"\n");
    }

    #[test]
    fn csv_keeps_signed_numeric_text() {
        let columns = cols(&["a"]);
        for text in ["-12", "+1.5e3", "-.5", "1.", "-7E-3"] {
            let rows = vec![vec![Value::Text(text.into())]];
            let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
            assert_eq!(out, format!("\"a\"\n\"{text}\"\n"), "{text} is a number, not a formula");
        }
    }

    #[test]
    fn csv_neutralises_formula_text() {
        let columns = cols(&["a"]);
        for text in ["-cmd", "=SUM(A1)", "+1+cmd", "-", "-.", "-1e"] {
            let rows = vec![vec![Value::Text(text.into())]];
            let out = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
            assert_eq!(out, format!("\"a\"\n\"'{text}\"\n"), "{text} must be neutralised");
        }
    }

    #[test]
    fn csv_neutralises_formula_header() {
        let columns = cols(&["=HYPERLINK(\"x\")"]);
        let out = render_csv(&columns, &[], &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"'=HYPERLINK(\"\"x\"\")\"\n");
    }

    #[test]
    fn text_csv_treats_every_field_as_free_text() {
        let records = vec![vec!["-cmd".to_string(), "12".to_string(), String::new()]];
        let out = render_text_csv(&["q", "n", "e"], &records, &CsvOptions::default()).unwrap();
        assert_eq!(out, "\"q\",\"n\",\"e\"\n\"'-cmd\",\"12\",\"\"\n");
    }

    #[test]
    fn plain_number_scanner_matches_the_grammar() {
        for yes in [
            "0", "12", "-12", "+12", "1.", ".5", "-.5", "1.25", "1e5", "1E+5", "-1.5e-3",
        ] {
            assert!(is_plain_number(yes), "{yes} should be a plain number");
        }
        for no in [
            "", "+", "-", ".", "e5", "1e", "1e+", "1.2.3", "1,5", " 1", "1 ", "0x10", "--1",
        ] {
            assert!(!is_plain_number(no), "{no:?} should not be a plain number");
        }
    }

    #[test]
    fn csv_null_modes() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Null]];
        let out_empty = render_csv(&columns, &rows, &CsvOptions::default()).unwrap();
        assert_eq!(out_empty, "\"a\"\n\"\"\n");
        let opts = CsvOptions {
            null_to_empty: false,
            ..Default::default()
        };
        let out_null = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out_null, "\"a\"\n\"NULL\"\n");
    }

    #[test]
    fn csv_lone_empty_field_stays_a_visible_row() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Null]];
        let out = render_csv(&columns, &rows, &plain()).unwrap();
        assert_eq!(out, "a\n\"\"\n");
    }

    #[test]
    fn csv_crlf_line_break() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Int(1)]];
        let opts = CsvOptions {
            line_break: CsvLineBreak::CrLf,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "a\r\n1\r\n");
    }

    #[test]
    fn csv_cr_line_break_quotes_embedded_line_feeds() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("x\ny".into())]];
        let opts = CsvOptions {
            line_break: CsvLineBreak::Cr,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "a\r\"x\ny\"\r");
    }

    #[test]
    fn csv_semicolon_delimiter() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1), Value::Int(2)]];
        let opts = CsvOptions {
            delimiter: CsvDelimiter::Semicolon,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "a;b\n1;2\n");
    }

    #[test]
    fn csv_header_off() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Int(1)]];
        let opts = CsvOptions {
            header_row: false,
            ..plain()
        };
        let out = render_csv(&columns, &rows, &opts).unwrap();
        assert_eq!(out, "1\n");
    }

    #[test]
    fn tsv_with_and_without_header() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1), Value::Null]];
        assert_eq!(render_tsv(&columns, &rows, true).unwrap(), "a\tb\n1\tNULL\n");
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "1\tNULL\n");
    }

    #[test]
    fn tsv_quotes_values_that_would_break_the_grid() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Text("line1\nline2".into()), Value::Text("has\ttab".into())]];
        assert_eq!(
            render_tsv(&columns, &rows, false).unwrap(),
            "\"line1\nline2\"\t\"has\ttab\"\n"
        );
    }

    #[test]
    fn tsv_doubles_quotes_inside_a_quoted_value() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("say \"hi\"".into())]];
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "\"say \"\"hi\"\"\"\n");
    }

    #[test]
    fn tsv_leaves_ordinary_values_bare() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain, value".into())]];
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "plain, value\n");
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
        let json = row_to_json(&columns, &row);
        assert_eq!(json["i"], serde_json::json!(5));
        assert_eq!(json["f"], serde_json::json!(1.5));
        assert_eq!(json["d"], serde_json::json!(9.99));
        assert_eq!(json["s"], serde_json::json!("hi"));
    }

    #[test]
    fn json_missing_cell_is_null() {
        let columns = cols(&["a", "b"]);
        let row = vec![Value::Int(1)];
        let json = row_to_json(&columns, &row);
        assert_eq!(json["b"], serde_json::Value::Null);
    }

    #[test]
    fn json_keeps_every_column_when_names_repeat() {
        let columns = cols(&["id", "name", "id"]);
        let row = vec![Value::Int(1), Value::Text("a".into()), Value::Int(2)];
        assert_eq!(json_field_names(&columns), vec!["id", "name", "id_2"]);
        let json = row_to_json(&columns, &row);
        assert_eq!(json["id"], serde_json::json!(1));
        assert_eq!(json["id_2"], serde_json::json!(2));
    }

    #[test]
    fn json_disambiguation_skips_a_name_a_real_column_already_holds() {
        let columns = cols(&["id", "id_2", "id"]);
        assert_eq!(json_field_names(&columns), vec!["id", "id_2", "id_3"]);
    }

    #[test]
    fn render_json_empty_rows_is_empty_array() {
        let columns = cols(&["a"]);
        assert_eq!(render_json(&columns, &[]), "[]");
    }

    #[test]
    fn markdown_escapes_pipe_and_converts_line_breaks() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has|pipe\nand newline".into())]];
        let out = render_markdown(&columns, &rows);
        assert_eq!(out, "| a |\n| --- |\n| has\\|pipe<br>and newline |");
    }

    #[test]
    fn in_clause_reports_the_values_it_skips() {
        let rows = vec![
            vec![Value::Text("O'Brien".into())],
            vec![Value::Null],
            vec![Value::Int(5)],
            vec![Value::Bool(true)],
        ];
        let out = render_in_clause(&rows, 0);
        assert_eq!(out.sql, "('O''Brien', 5, TRUE)");
        assert_eq!(out.skipped, 1);
    }

    #[test]
    fn in_clause_is_empty_rather_than_invalid_when_all_skipped() {
        let rows = vec![vec![Value::Null], vec![Value::Bytes(vec![1, 2])]];
        let out = render_in_clause(&rows, 0);
        assert_eq!(out.sql, "");
        assert_eq!(out.skipped, 2);
    }
}
