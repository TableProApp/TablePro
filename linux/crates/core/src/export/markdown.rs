use crate::column::{ColumnType, ResultColumn};
use crate::value::Value;

use super::encoder::{EncodeError, MarkdownEncoder, encode_rows};
use super::value_text::value_text;

pub(super) fn markdown_cell(value: &Value, column: &ColumnType) -> String {
    markdown_text(&value_text(value, column).unwrap_or_else(|| "NULL".to_string()))
}

/// A pipe or a line break, in a cell or a column name alike, would end
/// the cell or the row early.
pub(super) fn markdown_text(text: &str) -> String {
    text.replace('|', "\\|")
        .replace("\r\n", "<br>")
        .replace(['\r', '\n'], "<br>")
}

pub fn render_markdown(columns: &[ResultColumn], rows: &[Vec<Value>]) -> Result<String, EncodeError> {
    encode_rows(MarkdownEncoder::new(columns.into()), rows)
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn markdown_escapes_pipe_and_converts_line_breaks() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has|pipe\nand newline".into())]];

        let out = render_markdown(&columns, &rows).expect("the table");

        assert_eq!(out, "| a |\n| --- |\n| has\\|pipe<br>and newline |");
    }

    #[test]
    fn markdown_escapes_a_pipe_in_a_column_name() {
        let columns = cols(&["a|b", "c"]);
        let rows = vec![vec![Value::Int(1), Value::Int(2)]];

        let out = render_markdown(&columns, &rows).expect("the table");

        assert_eq!(out, "| a\\|b | c |\n| --- | --- |\n| 1 | 2 |");
    }
}
