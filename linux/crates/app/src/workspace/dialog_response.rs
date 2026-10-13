use std::cell::RefCell;
use std::rc::Rc;

use futures::channel::oneshot;
use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

/// Present `dialog` on `parent` and wait for the response it closes
/// with. A dialog closed without one, torn down with its window or
/// forced shut, answers with its close response.
///
/// `choose_future` is not used: its callback aborts the process when
/// the dialog goes away without a response.
pub(crate) async fn respond(dialog: &adw::AlertDialog, parent: &gtk::Widget) -> String {
    let fallback = dialog.close_response().to_string();
    let (sender, receiver) = oneshot::channel();
    let sender = Rc::new(RefCell::new(Some(sender)));
    let on_response = sender.clone();
    dialog.connect_response(None, move |_, response| {
        if let Some(sender) = on_response.borrow_mut().take() {
            let _ = sender.send(response.to_owned());
        }
    });
    let closed_fallback = fallback.clone();
    dialog.connect_closed(move |_| {
        if let Some(sender) = sender.borrow_mut().take() {
            let _ = sender.send(closed_fallback.clone());
        }
    });
    dialog.present(Some(parent));
    receiver.await.unwrap_or(fallback)
}

/// Answer the alert `window` shows with `response`, the way a click
/// would: the response, then the close.
#[cfg(test)]
pub(crate) fn answer(window: &impl IsA<adw::Window>, response: &str) -> bool {
    let Some(dialog) = window.as_ref().visible_dialog().and_downcast::<adw::AlertDialog>() else {
        return false;
    };
    dialog.emit_by_name::<()>("response", &[&response]);
    dialog.force_close();
    true
}

/// The alert `window` shows, if any.
#[cfg(test)]
pub(crate) fn visible_alert(window: &impl IsA<adw::Window>) -> Option<adw::AlertDialog> {
    window.as_ref().visible_dialog().and_downcast::<adw::AlertDialog>()
}
