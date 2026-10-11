use std::cell::Cell;
use std::rc::Rc;

use gtk4::{self as gtk, prelude::*};

use crate::services::column_widths::{ColumnWidthStore, saved_column_order};

pub(super) type Persist = (uuid::Uuid, String, ColumnWidthStore);

fn displayed_names(view: &gtk::ColumnView, columns: &[gtk::ColumnViewColumn], names: &[String]) -> Vec<String> {
    let list = view.columns();
    (0..list.n_items())
        .filter_map(|position| list.item(position)?.downcast::<gtk::ColumnViewColumn>().ok())
        .filter_map(|column| columns.iter().position(|candidate| *candidate == column))
        .filter_map(|index| names.get(index).cloned())
        .collect()
}

fn apply(view: &gtk::ColumnView, columns: &[gtk::ColumnViewColumn], order: &[usize]) {
    for column in columns {
        view.remove_column(column);
    }
    for index in order {
        if let Some(column) = columns.get(*index) {
            view.append_column(column);
        }
    }
}

pub(super) fn install(
    view: &gtk::ColumnView,
    columns: &[gtk::ColumnViewColumn],
    names: Vec<String>,
    persist: Option<Persist>,
) {
    let Some((id, table, store)) = persist else {
        return;
    };
    let saved = store.column_order(id, &table);
    if !saved.is_empty() {
        apply(view, columns, &saved_column_order(&names, &saved));
    }
    let settled = Rc::new(Cell::new(false));
    let columns = columns.to_vec();
    let weak_view = view.downgrade();
    let ready = settled.clone();
    view.columns().connect_items_changed(move |_, _, _, _| {
        if !ready.get() {
            return;
        }
        let Some(view) = weak_view.upgrade() else {
            return;
        };
        let current = displayed_names(&view, &columns, &names);
        if current.len() == names.len()
            && let Err(error) = store.set_column_order(id, &table, current)
        {
            tracing::warn!(%error, "column order was not saved");
        }
    });
    settled.set(true);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid(names: &[&str]) -> (gtk::ColumnView, Vec<gtk::ColumnViewColumn>) {
        gtk::init().unwrap();
        let view = gtk::ColumnView::new(None::<gtk::MultiSelection>);
        let columns: Vec<gtk::ColumnViewColumn> = names
            .iter()
            .map(|name| gtk::ColumnViewColumn::new(Some(name), None::<gtk::SignalListItemFactory>))
            .collect();
        for column in &columns {
            view.append_column(column);
        }
        (view, columns)
    }

    fn titles(view: &gtk::ColumnView) -> Vec<String> {
        let list = view.columns();
        (0..list.n_items())
            .filter_map(|position| list.item(position)?.downcast::<gtk::ColumnViewColumn>().ok())
            .filter_map(|column| column.title().map(|title| title.to_string()))
            .collect()
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_saved_order_is_shown_and_a_new_drag_is_saved() {
        let directory = tempfile::tempdir().unwrap();
        let store = ColumnWidthStore::load_in(directory.path());
        let id = uuid::Uuid::new_v4();
        let names: Vec<String> = ["id", "name", "email"].map(String::from).to_vec();
        store
            .set_column_order(id, "users", vec!["email".into(), "id".into()])
            .unwrap();

        let (view, columns) = grid(&["id", "name", "email"]);
        install(&view, &columns, names, Some((id, "users".into(), store.clone())));
        assert_eq!(titles(&view), ["email", "id", "name"]);

        view.remove_column(&columns[1]);
        view.insert_column(0, &columns[1]);
        assert_eq!(store.column_order(id, "users"), ["name", "email", "id"]);
    }
}
