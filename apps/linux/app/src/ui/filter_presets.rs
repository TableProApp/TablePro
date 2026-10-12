use std::cell::RefCell;
use std::rc::Rc;

use relm4::gtk;
use relm4::gtk::prelude::*;
use tablepro_core::FilterSet;
use uuid::Uuid;

use crate::services::named_filter_presets::NamedFilterPresetsStore;

pub struct FilterPresetContext {
    pub store: NamedFilterPresetsStore,
    pub connection: Uuid,
    pub schema: Option<String>,
    pub table: String,
    pub driver_id: String,
}

pub struct FilterPresetBar {
    pub(super) widget: gtk::Box,
    #[cfg(test)]
    selector: gtk::DropDown,
    #[cfg(test)]
    apply: gtk::Button,
}

pub fn build(
    context: FilterPresetContext,
    state: Rc<RefCell<FilterSet>>,
    columns: Rc<RefCell<Vec<tablepro_core::ColumnInfo>>>,
    on_apply: Rc<dyn Fn(FilterSet)>,
) -> FilterPresetBar {
    let names = Rc::new(RefCell::new(context.store.list(
        context.connection,
        context.schema.as_deref(),
        &context.table,
    )));
    let model = model(&names.borrow());
    let selector = gtk::DropDown::new(Some(model), None::<gtk::Expression>);
    selector.set_hexpand(true);
    let name = gtk::Entry::builder()
        .placeholder_text(crate::tr!("Name this filter"))
        .max_length(48)
        .hexpand(true)
        .build();
    let save = gtk::Button::with_label(&crate::tr!("Save as"));
    let apply = gtk::Button::with_label(&crate::tr!("Apply saved"));
    let rename = gtk::Button::with_label(&crate::tr!("Rename"));
    let delete = gtk::Button::with_label(&crate::tr!("Delete"));
    let status = gtk::Label::new(None);
    status.set_xalign(0.0);
    status.add_css_class("dim-label");
    let selection_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    selection_row.append(&selector);
    selection_row.append(&apply);
    selection_row.append(&delete);
    let edit_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    edit_row.append(&name);
    edit_row.append(&save);
    edit_row.append(&rename);

    let store = context.store.clone();
    let connection = context.connection;
    let schema = context.schema.clone();
    let table = context.table.clone();
    let names_for_save = names.clone();
    let selector_for_save = selector.clone();
    let name_for_save = name.clone();
    let status_for_save = status.clone();
    let state_for_save = state.clone();
    save.connect_clicked(move |_| {
        let result = store.save(
            connection,
            schema.as_deref(),
            &table,
            name_for_save.text().as_str(),
            state_for_save.borrow().clone(),
        );
        match result {
            Ok(()) => {
                let updated = store.list(connection, schema.as_deref(), &table);
                replace_names(&selector_for_save, &names_for_save, updated);
                status_for_save.set_text(&crate::tr!("Filter saved"));
                name_for_save.set_text("");
            }
            Err(error) => status_for_save.set_text(&error),
        }
    });

    let store = context.store.clone();
    let connection = context.connection;
    let schema = context.schema.clone();
    let table = context.table.clone();
    let names_for_apply = names.clone();
    let selector_for_apply = selector.clone();
    let status_for_apply = status.clone();
    let state_for_apply = state.clone();
    let columns_for_apply = columns;
    let driver_for_apply = context.driver_id.clone();
    apply.connect_clicked(move |_| {
        let Some(selected) = selected_name(&selector_for_apply, &names_for_apply) else {
            status_for_apply.set_text(&crate::tr!("Select a saved filter first"));
            return;
        };
        let Some(filter) = store.load(connection, schema.as_deref(), &table, &selected) else {
            replace_names(
                &selector_for_apply,
                &names_for_apply,
                store.list(connection, schema.as_deref(), &table),
            );
            status_for_apply.set_text(&crate::tr!("That saved filter is no longer available"));
            return;
        };
        if tablepro_core::build_filter_where(&driver_for_apply, &columns_for_apply.borrow(), &filter).is_err() {
            status_for_apply.set_text(&crate::tr!(
                "This saved filter no longer matches the table columns or types. Edit and save it again."
            ));
            return;
        }
        *state_for_apply.borrow_mut() = filter.clone();
        on_apply(filter);
        status_for_apply.set_text("");
    });

    let store = context.store.clone();
    let connection = context.connection;
    let schema = context.schema.clone();
    let table = context.table.clone();
    let names_for_rename = names.clone();
    let selector_for_rename = selector.clone();
    let name_for_rename = name.clone();
    let status_for_rename = status.clone();
    rename.connect_clicked(move |_| {
        let Some(selected) = selected_name(&selector_for_rename, &names_for_rename) else {
            status_for_rename.set_text(&crate::tr!("Select a saved filter first"));
            return;
        };
        match store.rename(
            connection,
            schema.as_deref(),
            &table,
            &selected,
            name_for_rename.text().as_str(),
        ) {
            Ok(()) => {
                replace_names(
                    &selector_for_rename,
                    &names_for_rename,
                    store.list(connection, schema.as_deref(), &table),
                );
                status_for_rename.set_text(&crate::tr!("Filter renamed"));
                name_for_rename.set_text("");
            }
            Err(error) => status_for_rename.set_text(&error),
        }
    });

    let store = context.store;
    let connection = context.connection;
    let schema = context.schema;
    let table = context.table;
    let names_for_delete = names.clone();
    let selector_for_delete = selector.clone();
    let status_for_delete = status.clone();
    delete.connect_clicked(move |_| {
        let Some(selected) = selected_name(&selector_for_delete, &names_for_delete) else {
            status_for_delete.set_text(&crate::tr!("Select a saved filter first"));
            return;
        };
        match store.delete(connection, schema.as_deref(), &table, &selected) {
            Ok(_) => {
                replace_names(
                    &selector_for_delete,
                    &names_for_delete,
                    store.list(connection, schema.as_deref(), &table),
                );
                status_for_delete.set_text(&crate::tr!("Filter deleted"));
            }
            Err(error) => status_for_delete.set_text(&error),
        }
    });

    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .margin_top(4)
        .margin_bottom(4)
        .build();
    column.append(&selection_row);
    column.append(&edit_row);
    column.append(&status);
    FilterPresetBar {
        widget: column,
        #[cfg(test)]
        selector,
        #[cfg(test)]
        apply,
    }
}

fn model(names: &[String]) -> gtk::StringList {
    let model = gtk::StringList::new(&[&crate::tr!("Saved filters")]);
    for name in names {
        model.append(name);
    }
    model
}

fn replace_names(selector: &gtk::DropDown, names: &Rc<RefCell<Vec<String>>>, updated: Vec<String>) {
    *names.borrow_mut() = updated;
    selector.set_model(Some(&model(&names.borrow())));
    selector.set_selected(0);
}

fn selected_name(selector: &gtk::DropDown, names: &Rc<RefCell<Vec<String>>>) -> Option<String> {
    let selected = selector.selected().checked_sub(1)? as usize;
    names.borrow().get(selected).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{ColumnInfo, FilterOp, FilterRule, FilterValue};

    fn filter(value: &str) -> FilterSet {
        FilterSet {
            rules: vec![FilterRule {
                column: "status".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(value.into())),
            }],
            ..FilterSet::default()
        }
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn applying_two_saved_filters_switches_the_rules_in_the_browse_editor() {
        relm4::adw::init().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let store = NamedFilterPresetsStore::load_at(directory.path().join("presets.json"));
        let connection = Uuid::new_v4();
        store
            .save(connection, Some("public"), "jobs", "Failed", filter("failed"))
            .unwrap();
        store
            .save(connection, Some("public"), "jobs", "Open", filter("open"))
            .unwrap();
        let context = FilterPresetContext {
            store,
            connection,
            schema: Some("public".into()),
            table: "jobs".into(),
            driver_id: "sqlite".into(),
        };
        let applied = Rc::new(RefCell::new(Vec::new()));
        let applied_callback = applied.clone();
        let columns = Rc::new(RefCell::new(vec![ColumnInfo {
            name: "status".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }]));
        let bar = build(
            context,
            Rc::new(RefCell::new(FilterSet::default())),
            columns.clone(),
            Rc::new(move |filter| applied_callback.borrow_mut().push(filter)),
        );
        bar.selector.set_selected(1);
        bar.apply.emit_clicked();
        bar.selector.set_selected(2);
        bar.apply.emit_clicked();
        columns.borrow_mut()[0].data_type = "integer".into();
        bar.selector.set_selected(1);
        bar.apply.emit_clicked();

        assert_eq!(applied.borrow().as_slice(), &[filter("failed"), filter("open")]);
    }
}
