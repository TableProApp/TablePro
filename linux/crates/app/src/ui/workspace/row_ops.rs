use gtk4::prelude::*;

use super::WorkspaceModel;

impl WorkspaceModel {
    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }

    pub(super) fn on_copy_to_clipboard(&self, text: String) {
        match clipboard_refusal(&text) {
            Some(refusal) => self.show_toast(&refusal),
            None => {
                self.toast_overlay.clipboard().set_text(&text);
                self.show_toast(&crate::i18n::gettext("Copied to clipboard"));
            }
        }
    }
}

/// Why `text` cannot go on the clipboard, if it cannot.
///
/// The clipboard takes a C string, so a NUL would cut the copy short,
/// and a cut copy pasted back would change the value without a word.
fn clipboard_refusal(text: &str) -> Option<String> {
    text.contains('\0')
        .then(|| crate::i18n::gettext("Values with a NUL character can't be copied"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_with_a_nul_is_refused() {
        assert!(clipboard_refusal("a\0b").is_some());
        assert_eq!(clipboard_refusal("a\tb\nc"), None);
    }
}
