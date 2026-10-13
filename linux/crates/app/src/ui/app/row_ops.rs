use relm4::adw::prelude::*;

use super::App;

impl App {
    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }

    pub(super) fn on_copy_to_clipboard(&self, text: String) {
        self.window.clipboard().set_text(&text);
        self.show_toast(&crate::i18n::gettext("Copied to clipboard"));
    }
}
