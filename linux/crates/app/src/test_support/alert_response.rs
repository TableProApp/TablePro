use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::AdwDialogExt;

/// Answer `dialog` with `response` the way its button does: with the
/// response as the signal's detail too, which a handler connected for
/// that one response needs. The dialog is closed after, as a click
/// closes it.
pub(crate) fn respond(dialog: &adw::AlertDialog, response: &str) {
    dialog.emit_by_name_with_details::<()>("response", glib::Quark::from_str(response), &[&response]);
    dialog.force_close();
}
