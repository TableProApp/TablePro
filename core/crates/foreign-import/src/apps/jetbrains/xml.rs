use roxmltree::{Document, Node};

// The IDE writes its XML as UTF-8. roxmltree refuses a DTD, so no entity is ever loaded.
pub(crate) fn document(data: &[u8]) -> Option<Document<'_>> {
    let text = std::str::from_utf8(data).ok()?;
    Document::parse(text.strip_prefix('\u{FEFF}').unwrap_or(text)).ok()
}

pub(crate) fn elements<'a, 'input>(
    document: &'a Document<'input>,
    name: &'a str,
) -> impl Iterator<Item = Node<'a, 'input>> + 'a {
    document
        .descendants()
        .filter(move |node| node.is_element() && node.has_tag_name(name))
}

pub(crate) fn child<'a, 'input>(node: Node<'a, 'input>, name: &str) -> Option<Node<'a, 'input>> {
    node.children()
        .find(|child| child.is_element() && child.has_tag_name(name))
}

// All the text under the node, as Foundation's `stringValue` gives it.
pub(crate) fn text(node: Node<'_, '_>) -> String {
    node.descendants()
        .filter(Node::is_text)
        .filter_map(|text| text.text())
        .collect()
}

pub(crate) fn child_text(node: Node<'_, '_>, name: &str) -> Option<String> {
    child(node, name).map(|child| text(child).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_joins_every_text_under_an_element_and_child_text_is_trimmed() {
        let data = "\u{FEFF}<a><b> one <c>two</c><![CDATA[ three]]>\n</b></a>".as_bytes();
        let document = document(data).expect("a document");
        let root = document.root_element();
        assert_eq!(child_text(root, "b").as_deref(), Some("one two three"));
        assert_eq!(child_text(root, "missing"), None);
    }

    #[test]
    fn a_document_with_a_dtd_or_bad_bytes_is_not_read() {
        assert!(document(b"<!DOCTYPE a [<!ENTITY e \"x\">]><a>&e;</a>").is_none());
        assert!(document(&[0xff, 0xfe, b'<']).is_none());
    }
}
