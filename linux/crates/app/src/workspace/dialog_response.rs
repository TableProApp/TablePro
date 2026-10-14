use std::cell::RefCell;
use std::rc::Rc;

use futures::channel::oneshot;
use gtk4 as gtk;
use gtk4::glib;
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
        // AdwAlertDialog emits `closed` before the response a click
        // chose, so the close response waits until that has had its turn.
        let sender = sender.clone();
        let fallback = closed_fallback.clone();
        glib::idle_add_local_once(move || {
            if let Some(sender) = sender.borrow_mut().take() {
                let _ = sender.send(fallback);
            }
        });
    });
    dialog.present(Some(parent));
    receiver.await.unwrap_or(fallback)
}

/// Answer the alert `window` shows with `response` by clicking its
/// button, so the signals come in the order a user's click sends them.
#[cfg(test)]
pub(crate) fn answer(window: &impl IsA<gtk::Widget>, response: &str) -> bool {
    let Some(dialog) = visible_alert(window) else {
        return false;
    };
    let label = dialog.response_label(response);
    let Some(button) = crate::test_support::descendants(&dialog)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some(label.as_str()))
    else {
        return false;
    };
    button.emit_clicked();
    true
}

/// The alert `window` shows, if any. `window` is an `AdwWindow` or an
/// `AdwApplicationWindow`, the two that host dialogs.
#[cfg(test)]
pub(crate) fn visible_alert(window: &impl IsA<gtk::Widget>) -> Option<adw::AlertDialog> {
    let widget = window.as_ref();
    let dialog = match widget.downcast_ref::<adw::ApplicationWindow>() {
        Some(window) => window.visible_dialog(),
        None => widget.downcast_ref::<adw::Window>()?.visible_dialog(),
    };
    dialog.and_downcast::<adw::AlertDialog>()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    fn alert(window: &adw::Window) -> (adw::AlertDialog, Rc<RefCell<Option<String>>>) {
        let dialog = adw::AlertDialog::new(Some("Saving Changes"), None);
        dialog.add_response("keep", "_Keep Open");
        dialog.add_response("stop", "_Stop Saving");
        dialog.set_close_response("keep");
        let answer = Rc::new(RefCell::new(None));
        let sink = answer.clone();
        let (shown, parent) = (dialog.clone(), window.clone().upcast::<gtk::Widget>());
        glib::spawn_future_local(async move {
            sink.replace(Some(respond(&shown, &parent).await));
        });
        wait_until(WAIT, || visible_alert(window).is_some()).expect("the alert");
        (dialog, answer)
    }

    #[gtk4::test]
    fn a_clicked_response_answers_and_closes_the_alert() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let (_dialog, answered) = alert(&window);

        assert!(answer(&window, "stop"));

        wait_until(WAIT, || answered.borrow().is_some()).expect("an answer");
        assert_eq!(answered.borrow().as_deref(), Some("stop"));
        wait_until(WAIT, || visible_alert(&window).is_none()).expect("the alert to close itself");
    }

    #[gtk4::test]
    fn an_alert_forced_shut_answers_with_its_close_response() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let (dialog, answer) = alert(&window);

        dialog.force_close();

        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().as_deref(), Some("keep"));
    }
}
