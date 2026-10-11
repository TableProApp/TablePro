use std::io::Write;

use super::error::ExportError;
use super::file::ResultWriter;
use super::value_to_text;
use crate::query::{ColumnInfo, Value};

pub(crate) struct HtmlWriter;

impl ResultWriter for HtmlWriter {
    fn begin(&mut self, output: &mut dyn Write, columns: &[ColumnInfo]) -> Result<(), ExportError> {
        output.write_all(
            b"<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>Exported rows</title>\n</head>\n<body>\n<table>\n<thead>\n<tr>",
        )?;
        for (index, column) in columns.iter().enumerate() {
            write!(output, "<th>{}</th>", escape_cell(&column.name, 0, index)?)?;
        }
        output.write_all(b"</tr>\n</thead>\n<tbody>\n")?;
        Ok(())
    }

    fn write_row(&mut self, output: &mut dyn Write, row_index: usize, row: &[Value]) -> Result<(), ExportError> {
        output.write_all(b"<tr>")?;
        for (index, value) in row.iter().enumerate() {
            match value_to_text(value) {
                Some(text) => write!(
                    output,
                    "<td>{}</td>",
                    escape_cell(&text, row_index.saturating_add(1), index)?
                )?,
                None => output.write_all(b"<td class=\"null\"></td>")?,
            }
        }
        output.write_all(b"</tr>\n")?;
        Ok(())
    }

    fn finish(&mut self, output: &mut dyn Write) -> Result<(), ExportError> {
        output.write_all(b"</tbody>\n</table>\n</body>\n</html>\n")?;
        Ok(())
    }
}

fn escape_cell(value: &str, row: usize, column: usize) -> Result<String, ExportError> {
    escape_html(value).map_err(|character| ExportError::HtmlCharacter {
        row,
        column: column.saturating_add(1),
        codepoint: character as u32,
    })
}

/// HTML5 named character references. A raw apostrophe or quotation mark is
/// harmless in element content but ends an attribute value, so both are
/// escaped here rather than only where an attribute is written. An HTML
/// parser turns every raw CR into LF and drops U+0000 from element content,
/// and a `&#0;` reference parses as U+FFFD, so CR is written as a numeric
/// reference and U+0000 cannot be represented.
fn escape_html(value: &str) -> Result<String, char> {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\0' => return Err(character),
            '\r' => escaped.push_str("&#13;"),
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    Ok(escaped)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> String {
        let mut writer = HtmlWriter;
        let mut output: Vec<u8> = Vec::new();
        writer.begin(&mut output, columns).unwrap();
        for (index, row) in rows.iter().enumerate() {
            writer.write_row(&mut output, index, row).unwrap();
        }
        writer.finish(&mut output).unwrap();
        String::from_utf8(output).unwrap()
    }

    #[test]
    fn a_cell_cannot_inject_markup_into_the_exported_page() {
        let columns = [super::super::test_support::column("<script>")];
        let rows = vec![vec![Value::Text("<img src=x onerror=\"alert('x')\">".into())]];

        let html = render(&columns, &rows);

        assert!(html.contains("<th>&lt;script&gt;</th>"), "{html}");
        assert!(
            html.contains("<td>&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;</td>"),
            "{html}"
        );
        assert!(!html.contains("<script>"), "{html}");
    }

    #[test]
    fn value_contract_html_preserves_carriage_returns_through_parser_normalization() {
        let columns = [super::super::test_support::column("a\rb")];
        let rows = vec![vec![Value::Text("a\rb\r\nc\n\t&#13;".into())]];

        let html = render(&columns, &rows);

        assert!(html.contains("<th>a&#13;b</th>"), "{html}");
        assert!(html.contains("<td>a&#13;b&#13;\nc\n\t&amp;#13;</td>"), "{html}");
        assert!(!html.contains('\r'), "{html}");
    }

    #[test]
    fn an_ampersand_is_escaped_once_and_a_null_cell_is_marked() {
        let columns = [super::super::test_support::column("a&b")];
        let rows = vec![vec![Value::Text("x & y".into())], vec![Value::Null]];

        let html = render(&columns, &rows);

        assert!(html.contains("<th>a&amp;b</th>"), "{html}");
        assert!(html.contains("<td>x &amp; y</td>"), "{html}");
        assert!(html.contains("<td class=\"null\"></td>"), "{html}");
    }
}
