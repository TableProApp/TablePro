use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;

use crate::services::change_tracker::RowKey;
use crate::ui::grid::{GridCell, GridRowIndex, RowObject, selected_positions};

/// The selected rows and the focused cell, by row key, so a page read
/// again can put them back wherever the rows land in it.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct SelectionSnapshot {
    keys: Vec<RowKey>,
    focus: Option<(RowKey, usize)>,
}

impl SelectionSnapshot {
    pub(crate) fn capture(selection: &gtk::MultiSelection, column_view: &gtk::ColumnView) -> Self {
        let keys = selected_positions(selection)
            .into_iter()
            .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
            .filter_map(|row| row.id().tracker_key())
            .collect();
        let focus = column_view
            .root()
            .and_downcast::<gtk::Window>()
            .and_then(|window| gtk::prelude::GtkWindowExt::focus(&window))
            .filter(|focus| focus.is_ancestor(column_view))
            .and_then(|focus| GridCell::from_focus(&focus))
            .and_then(|cell| Some((cell.row()?.id().tracker_key()?, cell.column())));
        Self { keys, focus }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.focus.is_none()
    }

    /// Rows no longer on the page stay unselected. `columns` are the
    /// view's columns in the order of the row's cells, which a drag in
    /// the header does not change.
    pub(crate) fn restore(
        &self,
        index: &mut GridRowIndex,
        store: &gio::ListStore,
        selection: &gtk::MultiSelection,
        column_view: &gtk::ColumnView,
        columns: &[gtk::ColumnViewColumn],
    ) {
        let selected = gtk::Bitset::new_empty();
        for key in &self.keys {
            if let Some(position) = index.position_in(store, key) {
                selected.add(position);
            }
        }
        let mask = gtk::Bitset::new_range(0, selection.n_items());
        selection.set_selection(&selected, &mask);
        let focused = self
            .focus
            .as_ref()
            .and_then(|(key, column)| Some((index.position_in(store, key)?, *column)));
        match focused {
            Some((position, column)) => {
                column_view.scroll_to(position, columns.get(column), gtk::ListScrollFlags::FOCUS, None);
            }
            // A sort can move the selection anywhere on the page.
            None if !selected.is_empty() => {
                column_view.scroll_to(selected.minimum(), None, gtk::ListScrollFlags::NONE, None);
            }
            None => {}
        }
    }
}
