use gtk4::pango;

use super::display_text::{auto_filled_sentinel, editable_null_sentinel};

/// How a pending change marks a cell's text, beside its tint, so the
/// change reads without colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextMark {
    Plain,
    Modified,
    /// Wins over `Modified`: an edited cell in a row marked for deletion
    /// is going away with it.
    PendingDelete,
}

/// How a grid's cells mark their text, built once per column view and
/// shared by every cell in it, so a bind sets a list it does not build.
/// Italic marks a placeholder. Pango attributes, because CSS
/// `text-decoration` does not reach an Inscription's text reliably.
#[derive(Debug)]
pub struct GridAttributes {
    modified: pango::AttrList,
    modified_placeholder: pango::AttrList,
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
        let list = |mark: TextMark, italic: bool| {
            let attrs = pango::AttrList::new();
            match mark {
                TextMark::Plain => {}
                TextMark::Modified => attrs.insert(pango::AttrInt::new_weight(pango::Weight::Bold)),
                TextMark::PendingDelete => attrs.insert(pango::AttrInt::new_strikethrough(true)),
            }
            if italic {
                attrs.insert(pango::AttrInt::new_style(pango::Style::Italic));
            }
            attrs
        };
        Self {
            modified: list(TextMark::Modified, false),
            modified_placeholder: list(TextMark::Modified, true),
            strikethrough: list(TextMark::PendingDelete, false),
            placeholder: list(TextMark::Plain, true),
            strikethrough_placeholder: list(TextMark::PendingDelete, true),
            editable_null: editable_null_sentinel(),
            auto_filled: auto_filled_sentinel(),
        }
    }

    /// `None` for plain text.
    pub fn for_text(&self, mark: TextMark, placeholder: bool) -> Option<&pango::AttrList> {
        match (mark, placeholder) {
            (TextMark::Plain, false) => None,
            (TextMark::Plain, true) => Some(&self.placeholder),
            (TextMark::Modified, false) => Some(&self.modified),
            (TextMark::Modified, true) => Some(&self.modified_placeholder),
            (TextMark::PendingDelete, false) => Some(&self.strikethrough),
            (TextMark::PendingDelete, true) => Some(&self.strikethrough_placeholder),
        }
    }
}
