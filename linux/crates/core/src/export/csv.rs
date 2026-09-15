use crate::column::{ColumnType, ResultColumn};
use crate::value::Value;

use super::csv_options::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
use super::value_text::value_text;
use super::{EncodeError, column_type, finish};

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

fn csv_cell(value: &Value, column: &ColumnType, opts: &CsvOptions) -> String {
    let Some(text) = value_text(value, column) else {
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

pub fn render_csv(columns: &[ResultColumn], rows: &[Vec<Value>], opts: &CsvOptions) -> Result<String, EncodeError> {
    let mut writer = csv_writer_builder(opts).from_writer(Vec::new());
    if opts.header_row {
        writer.write_record(columns.iter().map(|column| csv_header(&column.name, opts)))?;
    }
    for row in rows {
        writer.write_record(
            row.iter()
                .enumerate()
                .map(|(index, value)| csv_cell(value, column_type(columns, index), opts)),
        )?;
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

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

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
}
