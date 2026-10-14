use gtk4::pango;

use super::display_text::{auto_filled_sentinel, editable_null_sentinel};

/// How a grid's cells mark their text, built once per column view and
/// shared by every cell in it, so a bind sets a list it does not build.
/// Strikethrough marks a pending delete; italic marks a placeholder.
/// Pango attributes, because CSS `text-decoration` does not reach an
/// Inscription's text reliably.
#[derive(Debug)]
pub struct GridAttributes {
    strikethrough: pango::AttrList,
    placeholder: pango::AttrList,
    strikethrough_placeholder: pango::AttrList,
    /// The stand-in texts, translated once rather than on every bind.
    pub editable_null: String,
    pub auto_filled: String,
}

impl Default for GridAttributes {
    fn default() -> Self {
        Self::new()
    }
}

impl GridAttributes {
    pub fn new() -> Self {
        let list = |strikethrough: bool, italic: bool| {
            let attrs = pango::AttrList::new();
            if strikethrough {
                attrs.insert(pango::AttrInt::new_strikethrough(true));
            }
            if italic {
                attrs.insert(pango::AttrInt::new_style(pango::Style::Italic));
            }
            attrs
        };
        Self {
            strikethrough: list(true, false),
            placeholder: list(false, true),
            strikethrough_placeholder: list(true, true),
            editable_null: editable_null_sentinel(),
            auto_filled: auto_filled_sentinel(),
        }
    }

    /// `None` for plain text.
    pub fn for_text(&self, pending_delete: bool, placeholder: bool) -> Option<&pango::AttrList> {
        match (pending_delete, placeholder) {
            (false, false) => None,
            (true, false) => Some(&self.strikethrough),
            (false, true) => Some(&self.placeholder),
            (true, true) => Some(&self.strikethrough_placeholder),
        }
    }
}
