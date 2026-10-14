use gtk4::glib;
use gtk4::subclass::prelude::*;

use super::history_export::ExportKind;
use super::{HistoryDialog, QueryDestination, imp};

/// The dialog's actions. The ones for an entry take its id, so the row
/// buttons and the one row menu name the entry they act on.
pub(super) fn install(klass: &mut <imp::HistoryDialog as ObjectSubclass>::Class) {
    let id = Some(glib::VariantTy::INT64);
    klass.install_action("history.open", id, |dialog, _, target| {
        with_id(dialog, target, |dialog, id| {
            dialog.send_query(id, QueryDestination::NewTab)
        });
    });
    klass.install_action("history.replace", id, |dialog, _, target| {
        with_id(dialog, target, |dialog, id| {
            dialog.send_query(id, QueryDestination::CurrentTab)
        });
    });
    klass.install_action("history.pin", id, |dialog, _, target| {
        with_id(dialog, target, HistoryDialog::toggle_pin);
    });
    klass.install_action("history.copy", id, |dialog, _, target| {
        with_id(dialog, target, HistoryDialog::copy_query);
    });
    klass.install_action("history.delete", id, |dialog, _, target| {
        with_id(dialog, target, |dialog, id| dialog.delete_entries(vec![id]));
    });
    klass.install_action("history.delete-selected", None, |dialog, _, _| dialog.delete_selected());
    klass.install_action("history.export-sql", None, |dialog, _, _| {
        dialog.export_selected(ExportKind::Sql);
    });
    klass.install_action("history.export-csv", None, |dialog, _, _| {
        dialog.export_selected(ExportKind::Csv);
    });
    klass.install_action("history.clear-all", None, |dialog, _, _| dialog.confirm_clear_all());
    klass.install_action("history.show-in-files", None, |dialog, _, _| dialog.show_in_files());
    klass.install_action("history-row.menu", None, |dialog, _, _| dialog.popup_focused_row_menu());
}

fn with_id(dialog: &HistoryDialog, target: Option<&glib::Variant>, act: impl FnOnce(&HistoryDialog, i64)) {
    if let Some(id) = target.and_then(glib::Variant::get::<i64>) {
        act(dialog, id);
    }
}
