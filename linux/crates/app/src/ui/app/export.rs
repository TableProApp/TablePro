//! Pure grid-export renderers (CSV / JSON / SQL INSERT / Markdown).
//!
//! Kept free of GTK so unit tests can cover escaping, options, and
//! dialect-aware quoting without spinning up a window.

use tablepro_core::sql_dialect::quote_ident;
use tablepro_core::{QueryResult, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Csv,
    Json,
    SqlInsert,
    Markdown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    Lf,
    Crlf,
}

impl LineEnding {
    fn as_str(self) -> &'static str {
        match self {
            Self::Lf => "\n",
            Self::Crlf => "\r\n",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsvQuoteStyle {
    Minimal,
    Always,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CsvOptions {
    pub include_headers: bool,
    pub line_ending: LineEnding,
    pub utf8_bom: bool,
    pub quote_style: CsvQuoteStyle,
}

impl Default for CsvOptions {
    fn default() -> Self {
        Self {
            include_headers: true,
            line_ending: LineEnding::Lf,
            utf8_bom: false,
            quote_style: CsvQuoteStyle::Minimal,
        }
    }
}

pub fn render_csv(result: &QueryResult, options: CsvOptions) -> Vec<u8> {
    let ending = options.line_ending.as_str();
    let mut out = String::new();
    if options.include_headers {
        let cols: Vec<String> = result
            .columns
            .iter()
            .map(|c| csv_escape(&c.name, options.quote_style))
            .collect();
        out.push_str(&cols.join(","));
        out.push_str(ending);
    }
    for row in &result.rows {
        let cells: Vec<String> = row
            .iter()
            .map(|v| csv_escape(&value_to_export_text(v), options.quote_style))
            .collect();
        out.push_str(&cells.join(","));
        out.push_str(ending);
    }
    let mut bytes = Vec::new();
    if options.utf8_bom {
        bytes.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
    }
    bytes.extend_from_slice(out.as_bytes());
    bytes
}

pub fn render_json(result: &QueryResult) -> Vec<u8> {
    let cols: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    let rows: Vec<serde_json::Value> = result
        .rows
        .iter()
        .map(|row| {
            let mut obj = serde_json::Map::new();
            for (i, col) in cols.iter().enumerate() {
                let v = row.get(i).cloned().unwrap_or(Value::Null);
                obj.insert((*col).to_string(), value_to_json(&v));
            }
            serde_json::Value::Object(obj)
        })
        .collect();
    serde_json::to_vec_pretty(&rows).unwrap_or_default()
}

pub fn render_sql_insert(
    result: &QueryResult,
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
) -> Vec<u8> {
    let table_sql = match schema {
        Some(s) => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
        None => quote_ident(driver_id, table),
    };
    let cols: Vec<String> = result
        .columns
        .iter()
        .map(|c| quote_ident(driver_id, &c.name))
        .collect();
    let col_list = cols.join(", ");
    let mut out = String::new();
    for row in &result.rows {
        let values: Vec<String> = row.iter().map(format_sql_literal).collect();
        out.push_str(&format!(
            "INSERT INTO {table_sql} ({col_list}) VALUES ({});\n",
            values.join(", "),
        ));
    }
    out.into_bytes()
}

pub fn render_markdown(result: &QueryResult) -> Vec<u8> {
    let cols: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    let mut out = String::new();
    out.push('|');
    for col in &cols {
        out.push(' ');
        out.push_str(&md_escape(col));
        out.push_str(" |");
    }
    out.push('\n');
    out.push('|');
    for _ in &cols {
        out.push_str(" --- |");
    }
    out.push('\n');
    for row in &result.rows {
        out.push('|');
        for i in 0..cols.len() {
            let text = row.get(i).map(value_to_export_text).unwrap_or_default();
            out.push(' ');
            out.push_str(&md_escape(&text));
            out.push_str(" |");
        }
        out.push('\n');
    }
    out.into_bytes()
}

/// Render a `Value` as a SQL literal for clipboard / file export.
pub fn format_sql_literal(v: &Value) -> String {
    match v {
        Value::Null => "NULL".into(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Text(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Bytes(_) => "/* bytes omitted */ NULL".into(),
        Value::Date(d) => format!("'{}'", d.format("%Y-%m-%d")),
        Value::Time(t) => format!("'{}'", t.format("%H:%M:%S")),
        Value::DateTime(dt) => format!("'{}'", dt.format("%Y-%m-%d %H:%M:%S")),
        Value::TimestampTz(ts) => format!("'{}'", ts.to_rfc3339()),
        Value::Uuid(u) => format!("'{u}'"),
        Value::Json(j) => format!("'{}'", j.to_string().replace('\'', "''")),
    }
}

fn csv_escape(s: &str, style: CsvQuoteStyle) -> String {
    let needs_quotes = matches!(style, CsvQuoteStyle::Always)
        || s.contains(',')
        || s.contains('"')
        || s.contains('\n')
        || s.contains('\r');
    if needs_quotes {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn md_escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', " ").replace('\r', "")
}

fn value_to_export_text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Text(s) => s.clone(),
        Value::Bytes(b) => format!("<{} bytes>", b.len()),
        Value::Date(d) => d.format("%Y-%m-%d").to_string(),
        Value::Time(t) => t.format("%H:%M:%S").to_string(),
        Value::DateTime(dt) => dt.format("%Y-%m-%d %H:%M:%S").to_string(),
        Value::TimestampTz(ts) => ts.to_rfc3339(),
        Value::Decimal(d) => d.to_string(),
        Value::Uuid(u) => u.to_string(),
        Value::Json(j) => j.to_string(),
    }
}

fn value_to_json(v: &Value) -> serde_json::Value {
    use serde_json::Value as J;
    match v {
        Value::Null => J::Null,
        Value::Bool(b) => J::Bool(*b),
        Value::Int(i) => J::from(*i),
        Value::Float(f) => J::from(*f),
        Value::Text(s) => J::String(s.clone()),
        Value::Bytes(b) => J::String(format!("<{} bytes>", b.len())),
        Value::Date(d) => J::String(d.to_string()),
        Value::Time(t) => J::String(t.to_string()),
        Value::DateTime(dt) => J::String(dt.to_string()),
        Value::TimestampTz(ts) => J::String(ts.to_rfc3339()),
        Value::Decimal(d) => J::String(d.to_string()),
        Value::Uuid(u) => J::String(u.to_string()),
        Value::Json(j) => j.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::ColumnInfo;

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

    fn sample_result() -> QueryResult {
        QueryResult {
            columns: vec![col("id"), col("name")],
            rows: vec![
                vec![Value::Int(1), Value::Text("alice".into())],
                vec![Value::Int(2), Value::Text("a,b\"c".into())],
                vec![Value::Int(3), Value::Null],
            ],
            truncated: false,
        }
    }

    #[test]
    fn csv_default_includes_header_and_escapes() {
        let bytes = render_csv(&sample_result(), CsvOptions::default());
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(
            text,
            "id,name\n1,alice\n2,\"a,b\"\"c\"\n3,\n"
        );
    }

    #[test]
    fn csv_options_bom_crlf_no_header_always_quote() {
        let options = CsvOptions {
            include_headers: false,
            line_ending: LineEnding::Crlf,
            utf8_bom: true,
            quote_style: CsvQuoteStyle::Always,
        };
        let bytes = render_csv(&sample_result(), options);
        assert_eq!(&bytes[..3], &[0xEF, 0xBB, 0xBF]);
        let text = String::from_utf8(bytes[3..].to_vec()).unwrap();
        assert_eq!(text, "\"1\",\"alice\"\r\n\"2\",\"a,b\"\"c\"\r\n\"3\",\"\"\r\n");
    }

    #[test]
    fn json_exports_objects() {
        let bytes = render_json(&sample_result());
        let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v.as_array().unwrap().len(), 3);
        assert_eq!(v[2]["name"], serde_json::Value::Null);
    }

    #[test]
    fn sql_insert_quotes_postgres_idents_and_nulls() {
        let bytes = render_sql_insert(&sample_result(), "postgres", Some("public"), "users");
        let text = String::from_utf8(bytes).unwrap();
        assert!(text.contains("INSERT INTO \"public\".\"users\" (\"id\", \"name\") VALUES (1, 'alice');"));
        assert!(text.contains("VALUES (3, NULL);"));
        assert!(text.contains("'a,b''c'") || text.contains("a,b\"c"));
        assert!(text.contains("VALUES (2, 'a,b\"c');"));
    }

    #[test]
    fn sql_insert_mysql_backticks() {
        let bytes = render_sql_insert(&sample_result(), "mysql", None, "users");
        let text = String::from_utf8(bytes).unwrap();
        assert!(text.starts_with("INSERT INTO `users` (`id`, `name`) VALUES (1, 'alice');"));
    }

    #[test]
    fn markdown_table_escapes_pipes() {
        let mut result = sample_result();
        result.rows[0][1] = Value::Text("a|b".into());
        let text = String::from_utf8(render_markdown(&result)).unwrap();
        assert!(text.starts_with("| id | name |\n| --- | --- |\n"));
        assert!(text.contains("| 1 | a\\|b |"));
        assert!(text.contains("| 3 |  |"));
    }

    #[test]
    fn format_sql_literal_escapes_quotes() {
        assert_eq!(format_sql_literal(&Value::Text("O'Reilly".into())), "'O''Reilly'");
        assert_eq!(format_sql_literal(&Value::Null), "NULL");
        assert_eq!(format_sql_literal(&Value::Bool(true)), "true");
    }
}
