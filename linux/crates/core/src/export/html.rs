use crate::column::ResultColumn;
use crate::value::Value;

use super::column_type;
use super::value_text::value_text;

/// A result as a standalone HTML document.
///
/// A whole document rather than a bare `<table>` because the file is
/// opened in a browser, and a fragment without a charset declaration
/// is read as the browser's default encoding, which turns every
/// non-ASCII name into mojibake.
pub fn render_html(columns: &[ResultColumn], rows: &[Vec<Value>], title: &str) -> String {
    let mut out = String::with_capacity(rows.len() * columns.len() * 16);
    out.push_str("<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>");
    escape_into(&mut out, title);
    out.push_str("</title>\n<style>\n");
    out.push_str(STYLE);
    out.push_str("</style>\n</head>\n<body>\n<table>\n<thead>\n<tr>");
    for column in columns {
        out.push_str("<th>");
        escape_into(&mut out, &column.name);
        out.push_str("</th>");
    }
    out.push_str("</tr>\n</thead>\n<tbody>\n");
    for row in rows {
        out.push_str("<tr>");
        for (index, value) in row.iter().enumerate() {
            match value_text(value, column_type(columns, index)) {
                Some(text) => {
                    out.push_str("<td>");
                    escape_into(&mut out, &text);
                }
                // A NULL is marked rather than written as the word,
                // so it is not read back as a row holding the text
                // "NULL".
                None => out.push_str("<td class=\"null\">"),
            }
            out.push_str("</td>");
        }
        out.push_str("</tr>\n");
    }
    out.push_str("</tbody>\n</table>\n</body>\n</html>\n");
    out
}

const STYLE: &str = "table { border-collapse: collapse; font-family: sans-serif; font-size: 14px }\n\
th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; vertical-align: top }\n\
th { background: #f0f0f0 }\n\
td.null { background: #fafafa }\n\
td.null::after { content: \"NULL\"; color: #999; font-style: italic }\n";

fn escape_into(out: &mut String, text: &str) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            other => out.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn a_document_carries_its_own_encoding() {
        let html = render_html(&cols(&["tên"]), &[vec![Value::Text("Đà Nẵng".into())]], "t");

        assert!(html.starts_with("<!doctype html>"), "{html}");
        assert!(html.contains("<meta charset=\"utf-8\">"), "{html}");
        assert!(html.contains("Đà Nẵng"), "{html}");
    }

    #[test]
    fn markup_in_a_value_is_shown_not_run() {
        let rows = vec![vec![Value::Text("<script>alert(1)</script>".into())]];

        let html = render_html(&cols(&["a"]), &rows, "t");

        assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), "{html}");
        assert!(!html.contains("<script>"), "a value reached the document as markup");
    }

    #[test]
    fn markup_in_a_column_name_is_shown_not_run() {
        let html = render_html(&cols(&["<b>id</b>"]), &[], "t");

        assert!(html.contains("&lt;b&gt;id&lt;/b&gt;"), "{html}");
        assert!(!html.contains("<b>"), "a column name reached the document as markup");
    }

    #[test]
    fn a_null_is_told_apart_from_the_text_null() {
        let rows = vec![vec![Value::Null, Value::Text("NULL".into())]];

        let html = render_html(&cols(&["a", "b"]), &rows, "t");

        assert!(html.contains("<td class=\"null\"></td>"), "{html}");
        assert!(html.contains("<td>NULL</td>"), "{html}");
    }

    #[test]
    fn an_empty_result_still_lists_its_columns() {
        let html = render_html(&cols(&["a", "b"]), &[], "t");

        assert!(html.contains("<th>a</th><th>b</th>"), "{html}");
        assert!(html.contains("<tbody>\n</tbody>"), "{html}");
    }
}
