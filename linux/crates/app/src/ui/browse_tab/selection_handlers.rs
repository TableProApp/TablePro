use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;

use super::{BrowseModel, SelectionInput, SelectionSnapshot};
use crate::ui::grid::{DeleteAvailability, RowObject, delete_availability};

impl BrowseModel {
    pub(super) fn on_selection(&self, input: SelectionInput) {
        match input {
            SelectionInput::ClearSelection => {
                let Some(sel) = self.current_selection.as_ref() else {
                    return;
                };
                // Only a true multi-row selection; clearing a single
                // focused row strands the focus indicator.
                if sel.selection().size() < 2 {
                    return;
                }
                sel.unselect_all();
            }
        }
    }

    pub(super) fn selected_rows(&self) -> Vec<RowObject> {
        self.current_selection.as_ref().map(selected_rows).unwrap_or_default()
    }

    /// GtkMultiSelection emits no selection-changed when its rows are
    /// spliced, so a page that drops the selected rows comes through here.
    pub(super) fn sync_selection(&self) {
        let selected = self
            .current_selection
            .as_ref()
            .map_or(0, |sel| u32::try_from(sel.selection().size()).unwrap_or(u32::MAX));
        update_selection_chrome(&self.widgets.selection_label, selected);
        self.sync_delete_action();
    }

    /// The rows on screen can change under the selection without it
    /// changing, so this runs on every delta, page and load state too.
    /// Rows behind an error page count as none.
    pub(super) fn sync_delete_action(&self) {
        let rows = match self.shown_page() {
            Some(_) => self.selected_rows(),
            None => Vec::new(),
        };
        self.actions
            .follow_selection(u32::try_from(rows.len()).unwrap_or(u32::MAX));
        show_delete_availability(
            &self.actions.delete_rows,
            &self.widgets.delete_button,
            &rows,
            self.read_only,
        );
    }

    /// Keep the selection and the focused cell by row key before a sort,
    /// save or refresh reads the page again.
    pub(super) fn capture_selection(&mut self) {
        // A capture still pending (sort and save in quick succession)
        // is kept: the user was where the chain started.
        if self.pending_restore.is_some() {
            return;
        }
        let (Some(selection), Some(column_view)) = (self.current_selection.as_ref(), self.current_column_view.as_ref())
        else {
            return;
        };
        let snapshot = SelectionSnapshot::capture(selection, column_view);
        if !snapshot.is_empty() {
            self.pending_restore = Some(snapshot);
        }
    }

    /// Put back the selection captured before the page was read again,
    /// on the rows that are still on it. The capture is used up either
    /// way, so it cannot steer a later read.
    pub(super) fn restore_selection(&mut self) {
        let Some(snapshot) = self.pending_restore.take() else {
            return;
        };
        let (Some(store), Some(selection), Some(column_view)) = (
            self.list_store(),
            self.current_selection.clone(),
            self.current_column_view.clone(),
        ) else {
            return;
        };
        snapshot.restore(
            &mut self.row_index,
            &store,
            &selection,
            &column_view,
            &self.view_columns,
        );
    }
}

pub(super) fn selected_rows(selection: &gtk::MultiSelection) -> Vec<RowObject> {
    crate::ui::grid::selected_positions(selection)
        .into_iter()
        .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
        .collect()
}

/// The Delete key and button follow the action; the button's tooltip
/// says why it is off.
pub(super) fn show_delete_availability(
    action: &gio::SimpleAction,
    button: &gtk::Button,
    rows: &[RowObject],
    read_only: bool,
) {
    let availability = delete_availability(rows.iter().map(RowObject::id), read_only);
    action.set_enabled(availability == DeleteAvailability::Available);
    let explanation = match availability {
        DeleteAvailability::Unavailable(block) => block.explanation(),
        DeleteAvailability::Available => None,
    };
    let tooltip = explanation.unwrap_or_else(|| crate::i18n::gettext("Delete Selected Rows"));
    button.set_tooltip_text(Some(&tooltip));
}

/// Update the selection-count badge in response to a `MultiSelection`
/// change. Hidden for 0–1 rows; shows "{n} selected · press Delete to
/// remove" once the user multi-selects, so the affordance stays
/// discoverable without a toolbar Delete button.
pub(super) fn update_selection_chrome(label: &gtk::Label, n: u32) {
    if n <= 1 {
        label.set_visible(false);
        return;
    }
    let count = n.to_string();
    label.set_label(&crate::i18n::gettext_f(
        "{n} selected · press Delete to remove",
        &[("n", &count)],
    ));
    label.set_visible(true);
}
