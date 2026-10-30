use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{AiPolicy, DriverRegistry, ExternalAccess};
use tablepro_storage::{ImportChange, ImportEntry, ImportPreview};

use crate::services::saved_connection_object::subtitle_for;

pub(crate) const IMPORT: &str = "import";
const CANCEL: &str = "cancel";

/// The list a file can bring is long only when the user exported a long
/// one, so it scrolls past this height rather than growing the dialog.
const MAX_LIST_HEIGHT: i32 = 320;

/// The question before an import writes anything. Each connection shows
/// where it connects, so a name that matches a saved one but points at
/// another host is seen before it is saved.
pub(crate) fn import_preview_dialog(preview: &ImportPreview, drivers: &DriverRegistry) -> adw::AlertDialog {
    let count = preview.entries().len();
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::ngettext_f(
            "Import {n} Connection?",
            "Import {n} Connections?",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        )),
        Some(&crate::i18n::gettext(
            "Check where each one connects. A file you did not export yourself can point anywhere.",
        )),
    );
    let rows = gio::ListStore::new::<glib::BoxedAnyObject>();
    for entry in preview.entries() {
        rows.append(&glib::BoxedAnyObject::new(entry_text(entry, drivers)));
    }
    // A row is built only while it is on screen, so a file of thousands
    // of connections opens the dialog as fast as one of three.
    let list = gtk::ListView::builder()
        .model(&gtk::NoSelection::new(Some(rows)))
        .factory(&row_factory())
        .css_classes(["boxed-list"])
        .build();
    let scrolled = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(MAX_LIST_HEIGHT)
        .child(&list)
        .build();
    dialog.set_extra_child(Some(&scrolled));
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(IMPORT, &crate::i18n::gettext("Import"));
    dialog.set_response_appearance(IMPORT, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog
}

/// What one row shows.
struct EntryText {
    title: String,
    subtitle: String,
}

fn entry_text(entry: &ImportEntry, drivers: &DriverRegistry) -> EntryText {
    let saved = &entry.connection;
    let file_based = drivers
        .get(&saved.driver_id)
        .is_some_and(|driver| driver.capabilities().is_file_based());
    let change = match entry.change {
        ImportChange::Added => crate::i18n::gettext("New"),
        ImportChange::Updated => crate::i18n::gettext("Updated"),
    };
    let mut lines = vec![format!("{change} · {}", subtitle_for(saved, file_based, None))];
    // An updated entry keeps its own settings; only the list's labels
    // come from the file.
    if entry.change == ImportChange::Added {
        lines.extend(looser_settings(saved.external_access, saved.ai_policy));
    }
    EntryText {
        title: saved.name.clone(),
        subtitle: lines.join("\n"),
    }
}

fn row_factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
            // A name and a host are the file's text, never markup.
            let row = adw::ActionRow::builder().use_markup(false).build();
            item.set_activatable(false);
            item.set_child(Some(&row));
        }
    });
    factory.connect_bind(|_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(row), Some(text)) = (
            item.child().and_downcast::<adw::ActionRow>(),
            item.item().and_downcast::<glib::BoxedAnyObject>(),
        ) else {
            return;
        };
        let text = text.borrow::<EntryText>();
        row.set_title(&text.title);
        row.set_subtitle(&text.subtitle);
    });
    factory
}

/// What the file allows beyond what a new connection starts with.
fn looser_settings(access: ExternalAccess, policy: AiPolicy) -> Vec<String> {
    let mut lines = Vec::new();
    if access == ExternalAccess::ReadWrite {
        lines.push(crate::i18n::gettext("MCP clients can ask to write"));
    }
    if policy == AiPolicy::Allow {
        lines.push(crate::i18n::gettext("The AI assistant reads without asking"));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_settings_looser_than_a_new_connections_are_called_out() {
        assert!(looser_settings(ExternalAccess::ReadOnly, AiPolicy::Ask).is_empty());
        assert!(looser_settings(ExternalAccess::Blocked, AiPolicy::Never).is_empty());
        assert_eq!(looser_settings(ExternalAccess::ReadWrite, AiPolicy::Allow).len(), 2);
    }
}
