use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::ConnectionGroupName;

const CANCEL: &str = "cancel";
const CREATE: &str = "create";

/// Ask for the name of a new group. `None` when the user cancels.
///
/// Create stays off until the name could be saved and names no group
/// the list already has, so the dialog never closes on a name that is
/// then refused or that files the connection somewhere it already was.
pub(crate) async fn ask_group_name(
    parent: &gtk::Widget,
    existing: &[ConnectionGroupName],
) -> Option<ConnectionGroupName> {
    let (dialog, entry) = new_group_dialog(existing);
    if crate::workspace::respond(&dialog, parent).await != CREATE {
        return None;
    }
    ConnectionGroupName::new(&entry.text()).ok()
}

pub(super) fn new_group_dialog(existing: &[ConnectionGroupName]) -> (adw::AlertDialog, adw::EntryRow) {
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("New Group")), None);
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
    let existing = existing.to_vec();
    let answering = dialog.downgrade();
    entry.connect_changed(move |entry| {
        let usable = ConnectionGroupName::new(&entry.text()).is_ok_and(|name| !existing.contains(&name));
        if let Some(dialog) = answering.upgrade() {
            dialog.set_response_enabled(CREATE, usable);
        }
    });
    (dialog, entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn new_group_create_response_disabled_until_valid_unique_name() {
        let _ = adw::init();
        let work = ConnectionGroupName::new("Work").expect("a group name");

        let (dialog, entry) = new_group_dialog(&[work]);

        assert!(!dialog.is_response_enabled(CREATE), "an empty name can be created");
        for (typed, usable) in [
            ("   ", false),
            ("Work", false),
            (" Work ", false),
            ("Archive", true),
            (&"x".repeat(ConnectionGroupName::MAX_CHARS + 1), false),
            ("Staging", true),
        ] {
            entry.set_text(typed);
            assert_eq!(dialog.is_response_enabled(CREATE), usable, "{typed:?}");
        }
        assert_eq!(dialog.default_response().as_deref(), Some(CREATE));
        assert_eq!(dialog.close_response(), CANCEL);
    }
}
