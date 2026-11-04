use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{ConnectionGroup, ConnectionGroupName};

use crate::services::library_outline::LibraryOutline;

const CANCEL: &str = "cancel";
const RENAME: &str = "rename";

pub(super) async fn ask_group_rename(
    parent: &gtk::Widget,
    outline: &LibraryOutline,
    group: &ConnectionGroup,
) -> Option<ConnectionGroupName> {
    let (dialog, entry) = rename_group_dialog(&group.name, outline.sibling_names(group.parent_id, Some(group.id)));
    if crate::workspace::respond(&dialog, parent).await != RENAME {
        return None;
    }
    ConnectionGroupName::new(&entry.text())
        .ok()
        .filter(|name| *name != group.name)
}

// `taken` leaves the group itself out, so a change of case alone can be saved.
pub(super) fn rename_group_dialog(
    current: &ConnectionGroupName,
    taken: Vec<ConnectionGroupName>,
) -> (adw::AlertDialog, adw::EntryRow) {
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Rename Group")), None);
    let entry = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Name"))
        .text(current.as_str())
        .activates_default(true)
        .build();
    let rows = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    rows.add_css_class("boxed-list");
    rows.append(&entry);
    dialog.set_extra_child(Some(&rows));
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(RENAME, &crate::i18n::gettext("Rename"));
    dialog.set_response_appearance(RENAME, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(RENAME));
    dialog.set_close_response(CANCEL);
    dialog.set_response_enabled(RENAME, false);
    dialog.set_focus(Some(&entry));
    let (current, answering) = (current.clone(), dialog.downgrade());
    entry.connect_changed(move |entry| {
        let usable = ConnectionGroupName::new(&entry.text())
            .is_ok_and(|name| name != current && !taken.iter().any(|other| other.same_name(&name)));
        if let Some(dialog) = answering.upgrade() {
            dialog.set_response_enabled(RENAME, usable);
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
    fn rename_stays_off_while_the_name_is_empty_unchanged_or_taken() {
        let _ = adw::init();
        let (dialog, entry) = rename_group_dialog(&name("Work"), vec![name("Archive")]);

        assert_eq!(dialog.heading().as_deref(), Some("Rename Group"));
        assert_eq!(entry.text().as_str(), "Work");
        assert!(!dialog.is_response_enabled(RENAME), "an unchanged name can be saved");
        for (typed, usable) in [
            ("   ", false),
            ("Work", false),
            (" Work ", false),
            ("Archive", false),
            ("ARCHIVE", false),
            ("work", true),
            ("Office", true),
        ] {
            entry.set_text(typed);
            assert_eq!(dialog.is_response_enabled(RENAME), usable, "{typed:?}");
        }
        assert_eq!(dialog.default_response().as_deref(), Some(RENAME));
        assert_eq!(dialog.close_response(), CANCEL);
        assert_eq!(dialog.response_appearance(RENAME), adw::ResponseAppearance::Suggested);
    }

    #[gtk4::test]
    fn the_new_name_is_checked_against_the_groups_beside_it() {
        let _ = adw::init();
        let window = OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let eu = group("Eu", Some(work.id));
        let archive = group("Archive", None);
        let shown = Rc::new(outline(
            Vec::new(),
            vec![work, staging.clone(), eu, archive],
            Vec::new(),
        ));
        let answer = Rc::new(RefCell::new(None));
        let sink = answer.clone();
        let renamed = staging.clone();
        glib::spawn_future_local(async move {
            sink.replace(Some(ask_group_rename(&parent, &shown, &renamed).await));
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

        entry.set_text("EU");
        assert!(!dialog.is_response_enabled(RENAME), "a sibling's name can be taken");
        entry.set_text("Archive");
        assert!(dialog.is_response_enabled(RENAME), "a name at another level is refused");
        crate::test_support::respond(&dialog, RENAME);

        wait_until(WAIT, || answer.borrow().is_some()).expect("an answer");
        assert_eq!(answer.borrow().clone(), Some(Some(name("Archive"))));
    }
}
