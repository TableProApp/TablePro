use std::io::Write;

use super::error::ExportError;
use super::file::ResultWriter;
use super::value_to_text;
use crate::query::{ColumnInfo, Value};

pub fn render_markdown(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> String {
    let mut lines = Vec::with_capacity(rows.len() + 2);
    lines.push(markdown_header_line(columns));
    lines.push(markdown_separator_line(columns.len()));
    for row in rows {
        lines.push(markdown_row_line(row));
    }
    lines.join("\n")
}

pub(crate) fn markdown_header_line(columns: &[ColumnInfo]) -> String {
    format!(
        "| {} |",
        columns
            .iter()
            .map(|column| markdown_cell(&column.name))
            .collect::<Vec<_>>()
            .join(" | ")
    )
}

pub(crate) fn markdown_separator_line(columns: usize) -> String {
    format!("| {} |", vec!["---"; columns].join(" | "))
}

pub(crate) fn markdown_row_line(row: &[Value]) -> String {
    format!(
        "| {} |",
        row.iter().map(markdown_value_cell).collect::<Vec<_>>().join(" | ")
    )
}

fn markdown_cell(value: &str) -> String {
    let normalized = value.replace("\r\n", "\n");
    let mut escaped = String::with_capacity(normalized.len());
    for character in normalized.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '|' => escaped.push_str("\\|"),
            '\r' | '\n' => escaped.push_str("<br>"),
            '\\' => escaped.push_str("&#92;"),
            '`' => escaped.push_str("&#96;"),
            '*' => escaped.push_str("&#42;"),
            '_' => escaped.push_str("&#95;"),
            '~' => escaped.push_str("&#126;"),
            '[' => escaped.push_str("&#91;"),
            ']' => escaped.push_str("&#93;"),
            other => escaped.push(other),
        }
    }
    escaped
}

fn markdown_value_cell(value: &Value) -> String {
    let text = match value {
        Value::Null => return "NULL".to_string(),
        Value::Text(text) => serde_json::Value::String(text.clone()).to_string(),
        other => match value_to_text(other) {
            Some(text) => text,
            None => "NULL".to_string(),
        },
    };
    markdown_cell(&text)
}

pub(crate) struct MarkdownWriter {
    columns: usize,
}

impl MarkdownWriter {
    pub(crate) fn new() -> Self {
        Self { columns: 0 }
    }
}

impl ResultWriter for MarkdownWriter {
    fn begin(&mut self, output: &mut dyn Write, columns: &[ColumnInfo]) -> Result<(), ExportError> {
        self.columns = columns.len();
        writeln!(output, "{}", markdown_header_line(columns))?;
        writeln!(output, "{}", markdown_separator_line(self.columns))?;
        Ok(())
    }

    fn write_row(&mut self, output: &mut dyn Write, _index: usize, row: &[Value]) -> Result<(), ExportError> {
        writeln!(output, "{}", markdown_row_line(row))?;
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
    fn markdown_renderer_quotes_text_and_escapes_table_and_inline_markup() {
        let columns = vec![column("a|b"), column("empty")];
        let rows = vec![vec![Value::Text("first\r\nsecond|<tag>&".into()), Value::Null]];

        assert_eq!(
            render_markdown(&columns, &rows),
            "| a\\|b | empty |\n| --- | --- |\n| \"first&#92;r&#92;nsecond\\|&lt;tag&gt;&amp;\" | NULL |"
        );
    }

    #[test]
    fn markdown_renderer_distinguishes_text_null_from_sql_null() {
        let columns = [column("value")];
        let rows = [vec![Value::Text("NULL".into())], vec![Value::Null]];

        assert_eq!(
            render_markdown(&columns, &rows),
            "| value |\n| --- |\n| \"NULL\" |\n| NULL |"
        );
    }
}
