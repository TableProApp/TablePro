use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::workspace::PendingState;

pub(crate) fn confirm_discard(
    parent: &impl IsA<gtk::Widget>,
    pending: usize,
    state: impl Fn() -> PendingState + 'static,
    discard: impl Fn() + 'static,
) {
    present(parent.as_ref(), pending, Rc::new(state), Rc::new(discard));
}

fn present(parent: &gtk::Widget, pending: usize, state: Rc<dyn Fn() -> PendingState>, discard: Rc<dyn Fn()>) {
    let current = state();
    if current == PendingState::Saving {
        return;
    }
    let unknown = matches!(current, PendingState::OutcomeUnknown(_));
    let body = if unknown {
        crate::i18n::gettext(
            "The last save may have changed the database. Discarding this draft does not undo changes already saved.",
        )
    } else {
        crate::i18n::ngettext_f(
            "{n} unsaved change on this tab will be lost, and Undo cannot bring it back.",
            "{n} unsaved changes on this tab will be lost, and Undo cannot bring them back.",
            pending,
            &[("n", &pending.to_string())],
        )
    };
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Discard Changes?")), Some(&body));
    dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
    dialog.add_response("discard", &crate::i18n::gettext("Discard"));
    dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    let weak = parent.downgrade();
    dialog.connect_response(None, move |_, response| {
        if response != "discard" {
            return;
        }
        match state() {
            PendingState::Saving => {}
            PendingState::OutcomeUnknown(_) if !unknown => {
                // A save can settle while the prompt is open; its first warning no longer applies.
                if let Some(parent) = weak.upgrade() {
                    present(&parent, pending, state.clone(), discard.clone());
                }
            }
            _ => discard(),
        }
    });
    dialog.present(Some(parent));
}
