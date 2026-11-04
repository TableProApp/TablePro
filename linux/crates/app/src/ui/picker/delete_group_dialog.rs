use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

const CANCEL: &str = "cancel";
const DELETE: &str = "delete";

pub(super) async fn ask_delete_group(parent: &gtk::Widget, name: &str, subgroups: bool) -> bool {
    crate::workspace::respond(&delete_group_dialog(name, subgroups), parent).await == DELETE
}

pub(super) fn delete_group_dialog(name: &str, subgroups: bool) -> adw::AlertDialog {
    let body = if subgroups {
        crate::i18n::gettext("The groups inside it are deleted too. Its connections move to the top level.")
    } else {
        crate::i18n::gettext("Its connections move to the top level.")
    };
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext_f("Delete “{name}”?", &[("name", name)])),
        Some(&body),
    );
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(DELETE, &crate::i18n::gettext("Delete"));
    dialog.set_response_appearance(DELETE, adw::ResponseAppearance::Destructive);
    // Enter never deletes: the delete has no undo.
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gtk4::glib;

    use super::*;
    use crate::test_support::{OwnedWindow, wait_until};

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    #[gtk4::test]
    fn delete_names_the_group_and_cancel_is_the_default() {
        let _ = adw::init();

        let dialog = delete_group_dialog("Work", false);

        assert_eq!(dialog.heading().as_deref(), Some("Delete “Work”?"));
        assert_eq!(dialog.body().as_str(), "Its connections move to the top level.");
        assert_eq!(dialog.default_response().as_deref(), Some(CANCEL));
        assert_eq!(dialog.close_response(), CANCEL);
        assert_eq!(dialog.response_appearance(DELETE), adw::ResponseAppearance::Destructive);
    }

    #[gtk4::test]
    fn a_group_with_subgroups_says_they_go_too() {
        let _ = adw::init();

        let dialog = delete_group_dialog("Work", true);

        assert_eq!(
            dialog.body().as_str(),
            "The groups inside it are deleted too. Its connections move to the top level."
        );
    }

    fn asked(response: &str) -> bool {
        let _ = adw::init();
        let window = OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let answer = Rc::new(Cell::new(None));
        let sink = answer.clone();
        glib::spawn_future_local(async move {
            sink.set(Some(ask_delete_group(&parent, "Work", false).await));
        });
        wait_until(WAIT, || crate::workspace::visible_alert(&*window).is_some()).expect("the question");

        assert!(crate::workspace::answer(&*window, response), "no {response} button");

        wait_until(WAIT, || answer.get().is_some()).expect("an answer");
        answer.get().unwrap_or_default()
    }

    #[gtk4::test]
    fn only_delete_answers_yes() {
        assert!(asked(DELETE));
        assert!(!asked(CANCEL));
    }
}
