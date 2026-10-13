use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::DirtyTab;
use super::dialog_response::respond;

const CANCEL: &str = "cancel";
const CLOSE: &str = "close";

/// Whether the user agrees to end the editor connections of `tabs`,
/// whose open transactions the server then rolls back.
pub(crate) async fn confirm_open_transactions(parent: &gtk::Widget, tabs: &[DirtyTab]) -> bool {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Close With Open Transactions?")),
        Some(&crate::i18n::gettext_f(
            "Closing ends the database sessions of {tabs}. The server rolls back uncommitted work.",
            &[("tabs", &DirtyTab::names(tabs))],
        )),
    );
    dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
    dialog.add_response(CLOSE, &crate::i18n::gettext("_Close Anyway"));
    dialog.set_response_appearance(CLOSE, adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    respond(&dialog, parent).await == CLOSE
}
