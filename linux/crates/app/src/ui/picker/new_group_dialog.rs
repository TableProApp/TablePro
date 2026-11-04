use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::ConnectionGroupName;
use uuid::Uuid;

use crate::services::library_outline::LibraryOutline;

const CANCEL: &str = "cancel";
const CREATE: &str = "create";

// `under` is the parent group, `None` for the top level. A parent the outline lacks asks nothing.
pub(crate) async fn ask_group_name(
    parent: &gtk::Widget,
    outline: &LibraryOutline,
    under: Option<Uuid>,
) -> Option<ConnectionGroupName> {
    let path = match under {
        Some(group) => Some(outline.label(group)?),
        None => None,
    };
    let (dialog, entry) = new_group_dialog(path.as_deref(), outline.sibling_names(under, None));
    if crate::workspace::respond(&dialog, parent).await != CREATE {
        return None;
    }
    ConnectionGroupName::new(&entry.text()).ok()
}

// Create stays off for a name the store would refuse, so the dialog never closes on one.
pub(super) fn new_group_dialog(
    under: Option<&str>,
    taken: Vec<ConnectionGroupName>,
) -> (adw::AlertDialog, adw::EntryRow) {
    let (heading, body) = match under {
        Some(path) => (
            crate::i18n::gettext("New Subgroup"),
            Some(crate::i18n::gettext_f("In “{path}”", &[("path", path)])),
        ),
        None => (crate::i18n::gettext("New Group"), None),
    };
    let dialog = adw::AlertDialog::new(Some(&heading), body.as_deref());
    let entry = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Name"))
        .activates_default(true)
        .build();
    let rows = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    rows.add_css_class("boxed-list");
    rows.append(&entry);
    dialog.set_extra_child(Some(&rows));
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(CREATE, &crate::i18n::gettext("Create"));
    dialog.set_response_appearance(CREATE, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(CREATE));
    dialog.set_close_response(CANCEL);
    dialog.set_response_enabled(CREATE, false);
    dialog.set_focus(Some(&entry));
    let answering = dialog.downgrade();
    entry.connect_changed(move |entry| {
        let usable =
            ConnectionGroupName::new(&entry.text()).is_ok_and(|name| !taken.iter().any(|other| other.same_name(&name)));
        if let Some(dialog) = answering.upgrade() {
            dialog.set_response_enabled(CREATE, usable);
        }
    });
    (dialog, entry)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gtk4::glib;

    use super::*;
    use crate::test_support::{OwnedWindow, wait_until};
    use crate::ui::picker::connection_menu::tests::{group, outline};

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    fn name(text: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(text).expect("a group name")
    }

    #[gtk4::test]
    fn new_group_create_response_disabled_until_valid_unique_name() {
        let _ = adw::init();
        let (dialog, entry) = new_group_dialog(None, vec![name("Work"), name("Archive")]);

        assert_eq!(dialog.heading().as_deref(), Some("New Group"));
        assert_eq!(dialog.body().as_str(), "");
        assert!(!dialog.is_response_enabled(CREATE), "an empty name can be created");
        for (typed, usable) in [
            ("   ", false),
            ("Work", false),
            (" Work ", false),
            ("work", false),
            ("WORK", false),
            ("archive", false),
            ("Staging", true),
            (&"x".repeat(200), true),
            ("Work / Staging", true),
        ] {
            entry.set_text(typed);
            assert_eq!(dialog.is_response_enabled(CREATE), usable, "{typed:?}");
        }
        assert_eq!(dialog.default_response().as_deref(), Some(CREATE));
        assert_eq!(dialog.close_response(), CANCEL);
        assert_eq!(dialog.response_appearance(CREATE), adw::ResponseAppearance::Suggested);
    }

    #[gtk4::test]
    fn a_subgroup_names_where_it_goes() {
        let _ = adw::init();
        let (dialog, entry) = new_group_dialog(Some("Work / Staging"), vec![name("Eu")]);

        assert_eq!(dialog.heading().as_deref(), Some("New Subgroup"));
        assert_eq!(dialog.body().as_str(), "In “Work / Staging”");
        entry.set_text("eu");
        assert!(!dialog.is_response_enabled(CREATE), "a sibling's name can be taken");
        entry.set_text("Work");
        assert!(
            dialog.is_response_enabled(CREATE),
            "a name elsewhere in the tree is refused"
        );
    }

    #[gtk4::test]
    fn the_name_checks_only_the_groups_beside_the_new_one() {
        let _ = adw::init();
        let window = OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let shown = Rc::new(outline(Vec::new(), vec![work.clone(), staging], Vec::new()));
        let answer = Rc::new(RefCell::new(None));
        let (sink, asked) = (answer.clone(), shown.clone());
        glib::spawn_future_local(async move {
            sink.replace(Some(ask_group_name(&parent, &asked, Some(work.id)).await));
        });
        let mut dialog = None;
        wait_until(WAIT, || {
            dialog = crate::workspace::visible_alert(&*window);
            dialog.is_some()
        })
        .expect("the dialog");
        let dialog = dialog.expect("the dialog");
        let entry = crate::test_support::descendants(&dialog)
            .into_iter()
            .find_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .expect("the name row");

        assert_eq!(dialog.body().as_str(), "In “Work”");
        entry.set_text("staging");
        assert!(!dialog.is_response_enabled(CREATE));
        entry.set_text("Production");
        crate::test_support::respond(&dialog, CREATE);

        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().clone(), Some(Some(name("Production"))));
    }

    #[gtk4::test]
    fn cancel_answers_with_no_name() {
        let _ = adw::init();
        let window = OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let shown = Rc::new(outline(Vec::new(), Vec::new(), Vec::new()));
        let answer = Rc::new(RefCell::new(None));
        let sink = answer.clone();
        glib::spawn_future_local(async move {
            sink.replace(Some(ask_group_name(&parent, &shown, None).await));
        });
        wait_until(WAIT, || crate::workspace::visible_alert(&*window).is_some()).expect("the dialog");

        assert!(crate::workspace::answer(&*window, CANCEL));

        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().clone(), Some(None));
    }
}
