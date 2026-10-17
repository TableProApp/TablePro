use crate::column::ResultColumn;
use crate::value::Value;

use super::column_type;
use super::encoder::{EncodeError, XmlEncoder, encode_rows};
use super::value_text::value_text;

/// A result as XML.
///
/// The column name is an attribute rather than the element name,
/// because a SQL column may be called `order total` or `1`, and
/// neither is a name XML allows. Putting it in an attribute keeps
/// every result representable without renaming the user's columns.
pub fn render_xml(columns: &[ResultColumn], rows: &[Vec<Value>]) -> Result<String, EncodeError> {
    encode_rows(XmlEncoder::new(columns.into()), rows)
}

pub(super) const XML_HEAD: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>\n";

pub(super) const XML_TAIL: &str = "</rows>\n";

/// One row, or the column holding a character XML 1.0 cannot carry.
pub(super) fn xml_row<'a>(
    out: &mut String,
    columns: &[ResultColumn],
    row: impl IntoIterator<Item = &'a Value>,
) -> Result<(), EncodeError> {
    out.push_str("  <row>\n");
    for (index, value) in row.into_iter().enumerate() {
        let name = columns
            .get(index)
            .map(|column| column.name.as_str())
            .unwrap_or_default();
        let refused = || EncodeError::NotXmlText {
            column: super::encoder::column_name(columns, index),
        };
        out.push_str("    <field name=\"");
        escape_into(out, name, Position::Attribute).map_err(|_| refused())?;
        match value_text(value, column_type(columns, index)) {
            Some(text) => {
                out.push_str("\">");
                escape_into(out, &text, Position::Text).map_err(|_| refused())?;
                out.push_str("</field>\n");
            }
            // An empty element with the flag, so a NULL reads back as
            // one rather than as an empty string.
            None => out.push_str("\" null=\"true\"/>\n"),
        }
    }
    out.push_str("  </row>\n");
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Position {
    Text,
    Attribute,
}

/// A character XML 1.0 has no representation for.
struct NotXmlText;

/// Escape for a text or attribute position.
///
/// A parser reads a raw carriage return back as a line feed, and a raw
/// tab or line feed in an attribute as a space, so those go in as
/// character references. The control characters below `space` other
/// than tab, line feed and carriage return have no representation in
/// XML 1.0, not even as a reference, so a value holding one is refused
/// rather than written without it.
fn escape_into(out: &mut String, text: &str, position: Position) -> Result<(), NotXmlText> {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\r' => out.push_str("&#13;"),
            '\t' if position == Position::Attribute => out.push_str("&#9;"),
            '\n' if position == Position::Attribute => out.push_str("&#10;"),
            '\t' | '\n' => out.push(ch),
            // The surrogate range cannot appear in a Rust `char`, and
            // these two are the remaining non-characters XML refuses.
            other if (other as u32) < 0x20 || matches!(other, '\u{FFFE}' | '\u{FFFF}') => return Err(NotXmlText),
            other => out.push(other),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn a_column_name_xml_would_refuse_as_an_element_still_exports() {
        let columns = cols(&["order total", "1"]);
        let rows = vec![vec![Value::Int(2), Value::Int(3)]];

        let xml = render_xml(&columns, &rows).expect("the document");

        assert!(xml.contains("<field name=\"order total\">2</field>"), "{xml}");
        assert!(xml.contains("<field name=\"1\">3</field>"), "{xml}");
    }

    #[test]
    fn markup_in_a_value_is_escaped() {
        let rows = vec![vec![Value::Text("a < b & \"c\"".into())]];

        let xml = render_xml(&cols(&["a"]), &rows).expect("the document");

        assert!(xml.contains("a &lt; b &amp; &quot;c&quot;"), "{xml}");
    }

    #[test]
    fn a_null_is_told_apart_from_the_empty_string() {
        let rows = vec![vec![Value::Null, Value::Text(String::new())]];

        let xml = render_xml(&cols(&["a", "b"]), &rows).expect("the document");

        assert!(xml.contains("<field name=\"a\" null=\"true\"/>"), "{xml}");
        assert!(xml.contains("<field name=\"b\"></field>"), "{xml}");
    }

    fn encoded_row(columns: &[ResultColumn], row: &[Value]) -> Result<String, EncodeError> {
        use super::super::RowEncoder;

        let mut out = Vec::new();
        XmlEncoder::new(columns.into()).row(&mut out, &mut row.iter())?;
        Ok(String::from_utf8(out).expect("utf-8"))
    }

    #[test]
    fn a_carriage_return_survives_a_parser_reading_it_back() {
        let xml = encoded_row(&cols(&["a\rb"]), &[Value::Text("one\r\ntwo\rthree\tfour".into())]).expect("the row");

        assert!(
            xml.contains("<field name=\"a&#13;b\">one&#13;\ntwo&#13;three\tfour</field>"),
            "{xml}"
        );
    }

    #[test]
    fn a_break_in_a_column_name_is_kept_in_its_attribute() {
        let xml = encoded_row(&cols(&["a\tb\nc"]), &[Value::Int(1)]).expect("the row");

        assert!(xml.contains("<field name=\"a&#9;b&#10;c\">1</field>"), "{xml}");
    }

    #[test]
    fn a_character_xml_cannot_carry_is_refused_rather_than_dropped() {
        let refused = encoded_row(&cols(&["a"]), &[Value::Text("a\u{1}b\tc".into())]);
        let refused_name = encoded_row(&cols(&["a\u{1}"]), &[Value::Int(1)]);

        assert_eq!(refused, Err(EncodeError::NotXmlText { column: "a".to_owned() }));
        assert!(refused_name.is_err(), "{refused_name:?}");
    }

    #[test]
    fn an_empty_result_is_still_a_document() {
        let xml = render_xml(&cols(&["a"]), &[]).expect("the document");

        assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"), "{xml}");
        assert!(xml.contains("<rows>\n</rows>"), "{xml}");
    }
}
