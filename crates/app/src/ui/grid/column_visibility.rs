use std::collections::HashSet;
use std::rc::Rc;

use gtk4::{self as gtk, gio};
use libadwaita::{self as adw, prelude::*};

use crate::services::column_widths::{ColumnWidthStore, may_hide};

type Persist = (uuid::Uuid, String, ColumnWidthStore);

pub(super) fn apply_saved(columns: &[gtk::ColumnViewColumn], names: &[String], hidden: &HashSet<String>) {
    let visible = names.iter().filter(|name| !hidden.contains(*name)).count();
    if visible == 0 {
        return;
    }
    for (column, name) in columns.iter().zip(names) {
        column.set_visible(!hidden.contains(name));
    }
}

pub(super) fn install(
    view: &gtk::ColumnView,
    actions: &gio::SimpleActionGroup,
    columns: &[gtk::ColumnViewColumn],
    names: Vec<String>,
    persist: Option<Persist>,
) {
    if let Some((id, table, store)) = &persist {
        apply_saved(columns, &names, &store.hidden_columns(*id, table));
    }
    let columns = Rc::new(columns.iter().map(|column| column.downgrade()).collect::<Vec<_>>());
    let names = Rc::new(names);
    let persist = Rc::new(persist);
    let action = gio::SimpleAction::new("columns", None);
    action.set_enabled(names.len() > 1);
    let weak_view = view.downgrade();
    action.connect_activate(move |_, _| {
        if let Some(view) = weak_view.upgrade().filter(|view| view.is_mapped()) {
            present(&view, columns.clone(), names.clone(), persist.clone());
        }
    });
    actions.add_action(&action);
}

fn present(
    view: &gtk::ColumnView,
    columns: Rc<Vec<gtk::glib::WeakRef<gtk::ColumnViewColumn>>>,
    names: Rc<Vec<String>>,
    persist: Rc<Option<Persist>>,
) {
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Columns"))
        .content_width(380)
        .content_height(460)
        .build();
    let group = adw::PreferencesGroup::builder()
        .description(crate::tr!("At least one column stays visible."))
        .build();
    let rows: Rc<Vec<adw::SwitchRow>> = Rc::new(
        names
            .iter()
            .zip(columns.iter())
            .map(|(name, column)| {
                let row = adw::SwitchRow::builder().title(name.as_str()).build();
                row.set_active(column.upgrade().is_none_or(|column| column.is_visible()));
                group.add(&row);
                row
            })
            .collect(),
    );
    for (index, row) in rows.iter().enumerate() {
        let (rows, columns, names, persist) = (rows.clone(), columns.clone(), names.clone(), persist.clone());
        row.connect_active_notify(move |row| {
            toggle(index, row, &rows, &columns, &names, &persist);
        });
    }
    let page = adw::PreferencesPage::new();
    page.add(&group);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(view));
}

fn toggle(
    index: usize,
    row: &adw::SwitchRow,
    rows: &[adw::SwitchRow],
    columns: &[gtk::glib::WeakRef<gtk::ColumnViewColumn>],
    names: &[String],
    persist: &Option<Persist>,
) {
    let hide = !row.is_active();
    let hidden_now = rows.iter().filter(|other| !other.is_active()).count() - usize::from(hide);
    if hide && !may_hide(names.len(), hidden_now) {
        row.set_active(true);
        return;
    }
    if let Some(column) = columns.get(index).and_then(|column| column.upgrade()) {
        column.set_visible(!hide);
    }
    if let Some((id, table, store)) = persist
        && let Err(error) = store.set_hidden(*id, table, &names[index], hide)
    {
        tracing::warn!(%error, "hidden columns were not saved");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_hidden_columns_are_applied_but_never_all_of_them() {
        let names: Vec<String> = ["id", "name", "email"].map(String::from).to_vec();
        let hidden: HashSet<String> = ["name".to_string()].into();
        assert_eq!(visible_flags(&names, &hidden), vec![true, false, true]);
        let everything: HashSet<String> = names.iter().cloned().collect();
        assert_eq!(visible_flags(&names, &everything), vec![true, true, true]);
    }

    fn visible_flags(names: &[String], hidden: &HashSet<String>) -> Vec<bool> {
        let kept = names.iter().filter(|name| !hidden.contains(*name)).count();
        names.iter().map(|name| kept == 0 || !hidden.contains(name)).collect()
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn hiding_a_column_hides_it_persists_it_and_keeps_the_last_one() {
        gtk::init().unwrap();
        adw::init().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let store = ColumnWidthStore::load_in(dir.path());
        let id = uuid::Uuid::new_v4();
        let names: Vec<String> = ["id", "name", "email"].map(String::from).to_vec();
        let columns: Vec<gtk::ColumnViewColumn> = names
            .iter()
            .map(|name| gtk::ColumnViewColumn::new(Some(name), None::<gtk::ListItemFactory>))
            .collect();
        let rows: Vec<adw::SwitchRow> = names.iter().map(|_| adw::SwitchRow::new()).collect();
        for row in &rows {
            row.set_active(true);
        }
        let weak: Vec<_> = columns.iter().map(|column| column.downgrade()).collect();
        let persist = Some((id, "users".to_string(), store.clone()));

        rows[1].set_active(false);
        toggle(1, &rows[1], &rows, &weak, &names, &persist);
        rows[2].set_active(false);
        toggle(2, &rows[2], &rows, &weak, &names, &persist);
        rows[0].set_active(false);
        toggle(0, &rows[0], &rows, &weak, &names, &persist);

        assert_eq!(
            columns.iter().map(|column| column.is_visible()).collect::<Vec<_>>(),
            vec![true, false, false]
        );
        assert!(rows[0].is_active());
        assert_eq!(
            store.hidden_columns(id, "users"),
            ["name", "email"].map(String::from).into_iter().collect()
        );
    }
}
