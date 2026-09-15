use crate::column::{ColumnType, ResultColumn};
use crate::value::Value;

use super::column_type;
use super::value_text::value_text;

fn markdown_cell(value: &Value, column: &ColumnType) -> String {
    let text = value_text(value, column).unwrap_or_else(|| "NULL".to_string());
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
        let cells: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(index, value)| markdown_cell(value, column_type(columns, index)))
            .collect();
        lines.push(format!("| {} |", cells.join(" | ")));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn markdown_escapes_pipe_and_converts_line_breaks() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("has|pipe\nand newline".into())]];

        let out = render_markdown(&columns, &rows);

        assert_eq!(out, "| a |\n| --- |\n| has\\|pipe<br>and newline |");
    }
}
