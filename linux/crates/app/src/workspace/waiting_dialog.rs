use std::pin::pin;
use std::time::Duration;

use futures::future::{Either, select};
use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::dialog_response::respond;
use super::{CloseScope, WorkspaceHandle};

const KEEP: &str = "keep";
const STOP: &str = "stop";
/// A save that lands within this needs no dialog to say so.
const QUIET: Duration = Duration::from_millis(250);

/// Wait for the saves `scope` covers, with a dialog the user can stop
/// them from. True once none is running; false when the user chose to
/// keep the window open instead.
///
/// A schema save has no deadline, so Stop Saving is the only way out of
/// a hung one besides Keep Open.
pub(crate) async fn wait_for_saves(parent: &gtk::Widget, handle: &WorkspaceHandle, scope: CloseScope) -> bool {
    if let Either::Left(_) = select(pin!(handle.ledger().when_idle(scope)), glib::timeout_future(QUIET)).await {
        return true;
    }
    let mut stopping = false;
    loop {
        if handle.ledger().in_flight_in(scope) == 0 {
            return true;
        }
        let dialog = waiting_dialog(stopping);
        let idle = handle.ledger().when_idle(scope);
        match select(pin!(respond(&dialog, parent)), pin!(idle)).await {
            Either::Right(((), _)) => {
                dialog.force_close();
                return true;
            }
            Either::Left((response, _)) if response == STOP => {
                handle.stop_saves(scope);
                stopping = true;
            }
            Either::Left(_) => return false,
        }
    }
}

/// The alert a response closes, so a stop already sent shows as a new
/// one that can only be kept open.
fn waiting_dialog(stopping: bool) -> adw::AlertDialog {
    let body = match stopping {
        true => crate::i18n::gettext("Stopping the save."),
        false => crate::i18n::gettext("Wait for the save to finish, or stop it."),
    };
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Saving Changes")), Some(&body));
    dialog.add_response(KEEP, &crate::i18n::gettext("_Keep Open"));
    dialog.add_response(STOP, &crate::i18n::gettext("_Stop Saving"));
    dialog.set_response_appearance(STOP, adw::ResponseAppearance::Destructive);
    dialog.set_response_enabled(STOP, !stopping);
    dialog.set_close_response(KEEP);
    dialog.set_default_response(Some(KEEP));
    dialog
}
