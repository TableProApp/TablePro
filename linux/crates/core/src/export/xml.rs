use crate::column::ResultColumn;
use crate::value::Value;

use super::column_type;
use super::value_text::value_text;

/// A result as XML.
///
/// The column name is an attribute rather than the element name,
/// because a SQL column may be called `order total` or `1`, and
/// neither is a name XML allows. Putting it in an attribute keeps
/// every result representable without renaming the user's columns.
pub fn render_xml(columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
    let mut out = String::with_capacity(rows.len() * columns.len() * 24);
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>\n");
    for row in rows {
        out.push_str("  <row>\n");
        for (index, value) in row.iter().enumerate() {
            let name = columns
                .get(index)
                .map(|column| column.name.as_str())
                .unwrap_or_default();
            out.push_str("    <field name=\"");
            escape_into(&mut out, name);
            match value_text(value, column_type(columns, index)) {
                Some(text) => {
                    out.push_str("\">");
                    escape_into(&mut out, &text);
                    out.push_str("</field>\n");
                }
                // An empty element with the flag, so a NULL reads
                // back as one rather than as an empty string.
                None => out.push_str("\" null=\"true\"/>\n"),
            }
        }
        out.push_str("  </row>\n");
    }
    out.push_str("</rows>\n");
    out
}

/// Escape for both text and attribute positions, and drop what XML 1.0
/// cannot carry at all.
///
/// The control characters below `space`, apart from tab, newline and
/// carriage return, have no representation in XML 1.0: a numeric
/// reference to them is as invalid as the character itself. A document
/// containing one would fail to parse, so they are dropped and the
/// rest of the value is kept.
fn escape_into(out: &mut String, text: &str) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(ch),
            other if (other as u32) < 0x20 => {}
            // The surrogate range cannot appear in a Rust `char`, and
            // these two are the remaining non-characters XML refuses.
            '\u{FFFE}' | '\u{FFFF}' => {}
            other => out.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn a_column_name_xml_would_refuse_as_an_element_still_exports() {
        let columns = cols(&["order total", "1"]);
        let rows = vec![vec![Value::Int(2), Value::Int(3)]];

        let xml = render_xml(&columns, &rows);

        assert!(xml.contains("<field name=\"order total\">2</field>"), "{xml}");
        assert!(xml.contains("<field name=\"1\">3</field>"), "{xml}");
    }

    #[test]
    fn markup_in_a_value_is_escaped() {
        let rows = vec![vec![Value::Text("a < b & \"c\"".into())]];

        let xml = render_xml(&cols(&["a"]), &rows);

        assert!(xml.contains("a &lt; b &amp; &quot;c&quot;"), "{xml}");
    }

    #[test]
    fn a_null_is_told_apart_from_the_empty_string() {
        let rows = vec![vec![Value::Null, Value::Text(String::new())]];

        let xml = render_xml(&cols(&["a", "b"]), &rows);

        assert!(xml.contains("<field name=\"a\" null=\"true\"/>"), "{xml}");
        assert!(xml.contains("<field name=\"b\"></field>"), "{xml}");
    }

    #[test]
    fn a_character_xml_cannot_carry_is_dropped_rather_than_breaking_the_document() {
        let rows = vec![vec![Value::Text("a\u{1}b\tc".into())]];

        let xml = render_xml(&cols(&["a"]), &rows);

        assert!(xml.contains("<field name=\"a\">ab\tc</field>"), "{xml}");
        assert!(!xml.contains('\u{1}'), "an unrepresentable character survived");
    }

    #[test]
    fn an_empty_result_is_still_a_document() {
        let xml = render_xml(&cols(&["a"]), &[]);

        assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"), "{xml}");
        assert!(xml.contains("<rows>\n</rows>"), "{xml}");
    }
}
