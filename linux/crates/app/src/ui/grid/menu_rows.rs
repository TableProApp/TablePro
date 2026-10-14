use gtk4 as gtk;
use gtk4::prelude::*;

use super::selection::{selected_positions, selection_of};
use super::{GridCell, RowObject};

/// The rows a context menu item acts on: the whole selection when the
/// clicked row is in it, else the clicked row alone, so rows that moved
/// since the click never stand in for it.
pub fn menu_rows(selection: &gtk::MultiSelection, clicked: &RowObject, clicked_position: u32) -> Vec<RowObject> {
    let clicked_is_selected = selection.is_selected(clicked_position)
        && selection.item(clicked_position).and_downcast_ref::<RowObject>() == Some(clicked);
    if !clicked_is_selected {
        return vec![clicked.clone()];
    }
    selected_positions(selection)
        .into_iter()
        .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
        .collect()
}

/// The rows a menu opened on `cell` acts on, from the row the cell
/// shows when the item is chosen.
pub(super) fn menu_rows_of(column_view: &gtk::ColumnView, cell: &GridCell) -> Vec<RowObject> {
    let Some(row) = cell.row() else {
        return Vec::new();
    };
    match (selection_of(column_view), cell.position()) {
        (Some(selection), Some(position)) => menu_rows(&selection, &row, position),
        _ => vec![row],
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::gio;
    use gtk4::prelude::*;
    use tablepro_core::Value;

    use super::menu_rows;
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::RowObject;

    fn rows(n: i64) -> (gtk::MultiSelection, Vec<RowObject>) {
        let store = gio::ListStore::new::<RowObject>();
        let rows: Vec<RowObject> = (0..n)
            .map(|id| RowObject::persisted(RowKey::from_pk_values(&[Value::Int(id)]), vec![Value::Int(id)].into()))
            .collect();
        for row in &rows {
            store.append(row);
        }
        (gtk::MultiSelection::new(Some(store)), rows)
    }

    #[gtk4::test]
    fn menu_rows_uses_selection_when_clicked_row_is_selected() {
        let (selection, rows) = rows(5);
        selection.select_item(3, false);
        selection.select_item(1, false);

        assert_eq!(
            menu_rows(&selection, &rows[3], 3),
            vec![rows[1].clone(), rows[3].clone()],
            "the rows are not the selection in position order"
        );
    }

    #[gtk4::test]
    fn menu_rows_uses_only_clicked_row_outside_selection() {
        let (selection, rows) = rows(5);
        selection.select_range(0, 2, true);

        assert_eq!(menu_rows(&selection, &rows[4], 4), vec![rows[4].clone()]);
        assert_eq!(
            menu_rows(&selection, &rows[4], 1),
            vec![rows[4].clone()],
            "a selected row at the clicked position stood in for the clicked one"
        );
    }
}
