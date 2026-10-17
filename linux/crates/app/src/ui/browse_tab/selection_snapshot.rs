use std::collections::{HashMap, HashSet};

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;

use crate::services::change_tracker::RowKey;
use crate::ui::grid::{GridCell, RowObject, selected_positions};

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
        store: &gio::ListStore,
        selection: &gtk::MultiSelection,
        column_view: &gtk::ColumnView,
        columns: &[gtk::ColumnViewColumn],
    ) {
        let positions = self.positions_in(store);
        let selected = gtk::Bitset::new_empty();
        for key in &self.keys {
            if let Some(position) = positions.get(key) {
                selected.add(*position);
            }
        }
        let mask = gtk::Bitset::new_range(0, selection.n_items());
        selection.set_selection(&selected, &mask);
        let focused = self
            .focus
            .as_ref()
            .and_then(|(key, column)| Some((*positions.get(key)?, *column)));
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

    /// Where each captured row sits in `store` now, in one pass over it:
    /// a lookup per row would scan the page once for every row of a
    /// Select All.
    fn positions_in(&self, store: &gio::ListStore) -> HashMap<RowKey, u32> {
        let wanted: HashSet<&RowKey> = self
            .keys
            .iter()
            .chain(self.focus.as_ref().map(|(key, _)| key))
            .collect();
        (0..store.n_items())
            .filter_map(|position| {
                let key = store.item(position).and_downcast::<RowObject>()?.id().tracker_key()?;
                wanted.contains(&key).then_some((key, position))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use gtk4 as gtk;
    use gtk4::gio;
    use tablepro_core::Value;

    use super::SelectionSnapshot;
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::{RowObject, selected_positions};

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn page(ids: impl Iterator<Item = i64>) -> gio::ListStore {
        let store = gio::ListStore::new::<RowObject>();
        let rows: Vec<RowObject> = ids
            .map(|id| RowObject::persisted(Some(key(id)), vec![Value::Int(id)].into()))
            .collect();
        store.splice(0, 0, &rows);
        store
    }

    fn restored(snapshot: &SelectionSnapshot, store: &gio::ListStore) -> Vec<u32> {
        let selection = gtk::MultiSelection::new(Some(store.clone()));
        let view = gtk::ColumnView::new(Some(selection.clone()));
        snapshot.restore(store, &selection, &view, &[]);
        selected_positions(&selection)
    }

    #[gtk4::test]
    fn the_selection_follows_its_rows_to_where_they_landed() {
        let snapshot = SelectionSnapshot {
            keys: vec![key(3), key(9), key(1)],
            focus: None,
        };

        assert_eq!(restored(&snapshot, &page([9, 5, 3, 7].into_iter())), [0, 2]);
    }

    /// Select All on a large page, then a refresh: each row's place used
    /// to be a scan of the whole page.
    #[gtk4::test]
    fn a_whole_large_page_selection_comes_back_in_one_pass() {
        let rows = 20_000;
        let snapshot = SelectionSnapshot {
            keys: (0..rows).map(key).collect(),
            focus: Some((key(rows - 1), 0)),
        };
        let store = page((0..rows).rev());
        let started = Instant::now();

        let selected = restored(&snapshot, &store);

        assert_eq!(selected.len(), 20_000);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "restoring the selection took {:?}",
            started.elapsed()
        );
    }
}
