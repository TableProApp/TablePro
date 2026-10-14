use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::CloseBlockPrompt;
use super::dialog_response::respond;

const KEEP: &str = "keep";
const STOP: &str = "stop";

/// Whether the user stops the work `prompt` asks about. Dismissing the
/// alert keeps it running.
pub(crate) async fn ask_stop(parent: &gtk::Widget, prompt: &CloseBlockPrompt) -> bool {
    let dialog = adw::AlertDialog::new(Some(&prompt.heading), Some(&prompt.body));
    dialog.add_response(KEEP, &prompt.keep_label);
    dialog.add_response(STOP, &prompt.stop_label);
    dialog.set_response_appearance(STOP, adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some(KEEP));
    dialog.set_close_response(KEEP);
    respond(&dialog, parent).await == STOP
}
