use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::{ColumnInfo, Value};

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

    pub fn as_str(self) -> &'static str {
        match self {
            CsvDelimiter::Comma => ",",
            CsvDelimiter::Semicolon => ";",
            CsvDelimiter::Tab => "\t",
            CsvDelimiter::Pipe => "|",
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

    pub fn as_str(self) -> &'static str {
        match self {
            CsvLineBreak::Lf => "\n",
            CsvLineBreak::CrLf => "\r\n",
            CsvLineBreak::Cr => "\r",
        }
    }
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

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Full text of a value for export. Never truncates. `None` for Null.
pub fn value_to_text(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::Bool(b) => Some(if *b { "true".to_string() } else { "false".to_string() }),
        Value::Int(i) => Some(i.to_string()),
        Value::Float(f) => Some(f.to_string()),
        Value::Text(s) => Some(s.clone()),
        Value::Bytes(b) => Some(format!("0x{}", hex_encode(b))),
        Value::Date(d) => Some(d.format("%Y-%m-%d").to_string()),
        Value::Time(t) => Some(t.format("%H:%M:%S").to_string()),
        Value::DateTime(dt) => Some(dt.format("%Y-%m-%d %H:%M:%S").to_string()),
        Value::TimestampTz(dt) => Some(dt.to_rfc3339()),
        Value::Decimal(d) => Some(d.to_string()),
        Value::Uuid(u) => Some(u.to_string()),
        Value::Json(j) => Some(serde_json::to_string(j).unwrap_or_default()),
    }
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

fn quote_field(field: &str) -> String {
    format!("\"{}\"", field.replace('"', "\"\""))
}

/// The four characters a spreadsheet reads as the start of a formula.
pub const FORMULA_PREFIXES: [char; 4] = ['=', '+', '-', '@'];

/// A leading tab or carriage return leads a formula too: Excel strips
/// it before parsing the cell, so `\t=cmd|'/C calc'!A0` reaches the
/// formula engine exactly as `=cmd|…` would.
fn is_formula_lead(c: char) -> bool {
    FORMULA_PREFIXES.contains(&c) || c == '\t' || c == '\r'
}

/// `had_line_breaks` carries whether the raw value contained a line
/// break before `line_break_to_space` scrubbed it, so `IfNeeded`
/// still quotes a converted multi-line value even though the
/// resulting text no longer contains `\n`/`\r` itself.
fn escape_field(field: &str, opts: &CsvOptions, had_line_breaks: bool) -> String {
    let mut field = field.to_string();
    let mut neutralised = false;
    if opts.sanitize_formulas && field.starts_with(is_formula_lead) {
        field.insert(0, '\'');
        neutralised = true;
    }
    match opts.quote {
        CsvQuote::Always => quote_field(&field),
        CsvQuote::Never => field,
        CsvQuote::IfNeeded => {
            // A tab splits the field for every tab-aware consumer, and
            // a neutralised value has to keep its leading quote as
            // data rather than as the start of a bare token.
            let delim = opts.delimiter.as_str();
            if field.contains(delim) || field.contains(['"', '\n', '\r', '\t']) || had_line_breaks || neutralised {
                quote_field(&field)
            } else {
                field
            }
        }
    }
}

fn format_cell(value: &Value, opts: &CsvOptions) -> String {
    let Some(mut text) = value_to_text(value) else {
        let empty = if opts.null_to_empty {
            String::new()
        } else {
            "NULL".to_string()
        };
        return escape_field(&empty, opts, false);
    };
    let had_line_breaks = text.contains('\n') || text.contains('\r');
    if opts.line_break_to_space {
        text = text.replace("\r\n", " ").replace(['\r', '\n'], " ");
    }
    if opts.decimal == CsvDecimal::Comma && is_plain_decimal(&text) {
        text = text.replace('.', ",");
    }
    escape_field(&text, opts, had_line_breaks)
}

pub fn render_csv(columns: &[ColumnInfo], rows: &[Vec<Value>], opts: &CsvOptions) -> String {
    let delim = opts.delimiter.as_str();
    let line_break = opts.line_break.as_str();
    let mut out = String::new();
    if opts.header_row {
        let header: Vec<String> = columns.iter().map(|c| escape_field(&c.name, opts, false)).collect();
        out.push_str(&header.join(delim));
        out.push_str(line_break);
    }
    for row in rows {
        let cells: Vec<String> = row.iter().map(|v| format_cell(v, opts)).collect();
        out.push_str(&cells.join(delim));
        out.push_str(line_break);
    }
    out
}

/// A tab, a line break or a quote inside a value would move the
/// following text into the next column or the next row, so the value
/// is quoted and its own quotes doubled. That is what a spreadsheet
/// puts on the clipboard for a multi-line cell, and what Calc and
/// Excel parse back on paste; collapsing the character to a space
/// keeps the grid intact but hands the user a value the database
/// never held.
fn tsv_field(text: &str) -> String {
    if text.contains(['\t', '\n', '\r', '"']) {
        quote_field(text)
    } else {
        text.to_string()
    }
}

pub fn render_tsv(columns: &[ColumnInfo], rows: &[Vec<Value>], with_headers: bool) -> String {
    let mut lines: Vec<String> = Vec::new();
    if with_headers {
        let header: Vec<String> = columns.iter().map(|c| tsv_field(&c.name)).collect();
        lines.push(header.join("\t"));
    }
    for row in rows {
        let cells: Vec<String> = row
            .iter()
            .map(|v| tsv_field(&value_to_text(v).unwrap_or_else(|| "NULL".to_string())))
            .collect();
        lines.push(cells.join("\t"));
    }
    lines.join("\n")
}

fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::Value::Bool(*b),
        Value::Int(i) => serde_json::Value::Number((*i).into()),
        Value::Float(f) => serde_json::Number::from_f64(*f)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        Value::Decimal(d) => {
            let s = d.to_string();
            match s.parse::<serde_json::Number>() {
                Ok(n) => serde_json::Value::Number(n),
                Err(_) => serde_json::Value::String(s),
            }
        }
        Value::Json(j) => j.clone(),
        other => match value_to_text(other) {
            Some(s) => serde_json::Value::String(s),
            None => serde_json::Value::Null,
        },
    }
}

/// One JSON key per column, in column order. A join can return the
/// same column name twice (`SELECT a.id, b.id …`) and a JSON object
/// keyed by name alone would keep the last of them and drop the rest,
/// so a repeat is suffixed `_2`, `_3`, … until it is unique against
/// every name already taken, including the literal names of later
/// columns.
pub fn json_field_names(columns: &[ColumnInfo]) -> Vec<String> {
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

pub fn row_to_json(columns: &[ColumnInfo], row: &[Value]) -> serde_json::Value {
    row_to_json_object(&json_field_names(columns), row)
}

pub fn render_json(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> String {
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

pub fn render_markdown(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> String {
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
        Value::Int(_) | Value::Float(_) | Value::Decimal(_) => value_to_text(v),
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
    use rust_decimal::Decimal;
    use std::str::FromStr;
    use uuid::Uuid;

    use super::*;

    fn col(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        }
    }

    fn cols(names: &[&str]) -> Vec<ColumnInfo> {
        names.iter().map(|n| col(n)).collect()
    }

    #[test]
    fn value_to_text_covers_every_variant() {
        assert_eq!(value_to_text(&Value::Null), None);
        assert_eq!(value_to_text(&Value::Bool(true)), Some("true".to_string()));
        assert_eq!(value_to_text(&Value::Bool(false)), Some("false".to_string()));
        assert_eq!(value_to_text(&Value::Int(42)), Some("42".to_string()));
        assert_eq!(value_to_text(&Value::Float(1.5)), Some("1.5".to_string()));
        assert_eq!(value_to_text(&Value::Text("hi".into())), Some("hi".to_string()));
        assert_eq!(
            value_to_text(&Value::Bytes(vec![0xde, 0xad])),
            Some("0xdead".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Date(NaiveDate::from_ymd_opt(2024, 1, 2).unwrap())),
            Some("2024-01-02".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Time(NaiveTime::from_hms_opt(13, 5, 9).unwrap())),
            Some("13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::DateTime(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .unwrap()
                    .and_hms_opt(13, 5, 9)
                    .unwrap()
            )),
            Some("2024-01-02 13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Decimal(Decimal::from_str("12.30").unwrap())),
            Some("12.30".to_string())
        );
        let uuid = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(value_to_text(&Value::Uuid(uuid)), Some(uuid.to_string()));
        assert_eq!(
            value_to_text(&Value::Json(serde_json::json!({"a": 1}))),
            Some("{\"a\":1}".to_string())
        );
    }

    #[test]
    fn csv_defaults_render_comma_lf_if_needed() {
        let columns = cols(&["id", "name"]);
        let rows = vec![vec![Value::Int(1), Value::Text("Alice".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(out, "id,name\n1,Alice\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_delimiter() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has,comma".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(out, "a\n\"has,comma\"\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_quote_char() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("say \"hi\"".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(out, "a\n\"say \"\"hi\"\"\"\n");
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_original_line_break_even_when_converted() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("line1\nline2".into())]];
        let opts = CsvOptions {
            line_break_to_space: true,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "a\n\"line1 line2\"\n");
    }

    #[test]
    fn csv_quote_always_quotes_everything() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain".into())]];
        let opts = CsvOptions {
            quote: CsvQuote::Always,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "\"a\"\n\"plain\"\n");
    }

    #[test]
    fn csv_quote_never_quotes_nothing_even_with_delimiter() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has,comma".into())]];
        let opts = CsvOptions {
            quote: CsvQuote::Never,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "a\nhas,comma\n");
    }

    #[test]
    fn csv_sanitizes_formula_prefixes() {
        // A neutralised value is quoted so its leading apostrophe
        // reaches the spreadsheet as data rather than as a text marker
        // the importer swallows.
        let columns = cols(&["a"]);
        for ch in ['=', '+', '-', '@'] {
            let rows = vec![vec![Value::Text(format!("{ch}cmd"))]];
            let out = render_csv(&columns, &rows, &CsvOptions::default());
            assert_eq!(out, format!("a\n\"'{ch}cmd\"\n"), "prefix {ch} should be sanitized");
        }
    }

    #[test]
    fn csv_sanitizes_formula_lead_hidden_behind_whitespace() {
        let columns = cols(&["a"]);
        for lead in ['\t', '\r'] {
            let rows = vec![vec![Value::Text(format!("{lead}=cmd|'/C calc'!A0"))]];
            let out = render_csv(&columns, &rows, &CsvOptions::default());
            let expected = format!("a\n\"'{lead}=cmd|'/C calc'!A0\"\n");
            assert_eq!(out, expected, "lead {lead:?} should be sanitized and quoted");
        }
    }

    #[test]
    fn csv_quote_if_needed_triggers_on_tab_and_on_neutralised_value() {
        let columns = cols(&["a"]);
        let tabbed = vec![vec![Value::Text("has\ttab".into())]];
        assert_eq!(
            render_csv(&columns, &tabbed, &CsvOptions::default()),
            "a\n\"has\ttab\"\n"
        );
        let formula = vec![vec![Value::Text("=SUM(A1)".into())]];
        assert_eq!(
            render_csv(&columns, &formula, &CsvOptions::default()),
            "a\n\"'=SUM(A1)\"\n"
        );
    }

    #[test]
    fn csv_does_not_sanitize_non_formula_prefixes() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain text".into())]];
        let out = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(out, "a\nplain text\n");
    }

    #[test]
    fn csv_decimal_comma_only_for_plain_decimals() {
        let columns = cols(&["a"]);
        let opts = CsvOptions {
            decimal: CsvDecimal::Comma,
            delimiter: CsvDelimiter::Semicolon,
            ..Default::default()
        };
        assert_eq!(
            render_csv(&columns, &[vec![Value::Text("1.5".into())]], &opts),
            "a\n1,5\n"
        );
        assert_eq!(
            render_csv(&columns, &[vec![Value::Text("1e5".into())]], &opts),
            "a\n1e5\n"
        );
        assert_eq!(
            render_csv(&columns, &[vec![Value::Text("12".into())]], &opts),
            "a\n12\n"
        );
        assert_eq!(
            render_csv(&columns, &[vec![Value::Text("1.2.3".into())]], &opts),
            "a\n1.2.3\n"
        );
    }

    #[test]
    fn csv_null_modes() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Null]];
        let out_empty = render_csv(&columns, &rows, &CsvOptions::default());
        assert_eq!(out_empty, "a\n\n");
        let opts = CsvOptions {
            null_to_empty: false,
            ..Default::default()
        };
        let out_null = render_csv(&columns, &rows, &opts);
        assert_eq!(out_null, "a\nNULL\n");
    }

    #[test]
    fn csv_crlf_line_break() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Int(1)]];
        let opts = CsvOptions {
            line_break: CsvLineBreak::CrLf,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "a\r\n1\r\n");
    }

    #[test]
    fn csv_semicolon_delimiter() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1), Value::Int(2)]];
        let opts = CsvOptions {
            delimiter: CsvDelimiter::Semicolon,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "a;b\n1;2\n");
    }

    #[test]
    fn csv_header_off() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Int(1)]];
        let opts = CsvOptions {
            header_row: false,
            ..Default::default()
        };
        let out = render_csv(&columns, &rows, &opts);
        assert_eq!(out, "1\n");
    }

    #[test]
    fn tsv_with_and_without_header() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1), Value::Null]];
        assert_eq!(render_tsv(&columns, &rows, true), "a\tb\n1\tNULL");
        assert_eq!(render_tsv(&columns, &rows, false), "1\tNULL");
    }

    #[test]
    fn tsv_quotes_values_that_would_break_the_grid() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Text("line1\nline2".into()), Value::Text("has\ttab".into())]];
        assert_eq!(render_tsv(&columns, &rows, false), "\"line1\nline2\"\t\"has\ttab\"");
    }

    #[test]
    fn tsv_doubles_quotes_inside_a_quoted_value() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("say \"hi\"".into())]];
        assert_eq!(render_tsv(&columns, &rows, false), "\"say \"\"hi\"\"\"");
    }

    #[test]
    fn tsv_leaves_ordinary_values_bare() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain, value".into())]];
        assert_eq!(render_tsv(&columns, &rows, false), "plain, value");
    }

    #[test]
    fn json_number_vs_string_handling() {
        let columns = cols(&["i", "f", "d", "s"]);
        let row = vec![
            Value::Int(5),
            Value::Float(1.5),
            Value::Decimal(Decimal::from_str("9.99").unwrap()),
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
