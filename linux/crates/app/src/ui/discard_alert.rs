use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

/// Ask before Discard drops a tab's pending changes. The undo history
/// goes with them, so the alert is the only chance to keep them.
pub(crate) fn confirm_discard(
    parent: &impl IsA<gtk::Widget>,
    pending: usize,
    discard: impl Fn() + 'static,
) -> adw::AlertDialog {
    let body = crate::i18n::ngettext_f(
        "{n} unsaved change on this tab will be lost, and Undo cannot bring it back.",
        "{n} unsaved changes on this tab will be lost, and Undo cannot bring them back.",
        u32::try_from(pending).unwrap_or(u32::MAX),
        &[("n", &pending.to_string())],
    );
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Discard Changes?")), Some(&body));
    dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
    dialog.add_response("discard", &crate::i18n::gettext("Discard"));
    dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.connect_response(None, move |_, response| {
        if response == "discard" {
            discard();
        }
    });
    dialog.present(Some(parent));
    dialog
}
