use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::{QueryResult, Value};

use crate::ui::row_store::RowStore;

use super::local_sort;

#[derive(Clone)]
pub(crate) struct LocalResultView(Rc<RefCell<LocalResultViewState>>);

struct LocalResultViewState {
    result: Arc<QueryResult>,
    store: Option<RowStore>,
    selection: Option<gtk4::MultiSelection>,
    filter: Option<(usize, Value)>,
    sort: Option<(usize, bool)>,
    controls: gtk4::Box,
    status: gtk4::Label,
}

impl LocalResultView {
    pub(crate) fn new(result: Arc<QueryResult>) -> Self {
        let controls = gtk4::Box::builder()
            .spacing(6)
            .visible(false)
            .margin_start(8)
            .margin_end(8)
            .margin_top(4)
            .margin_bottom(4)
            .build();
        let status = gtk4::Label::builder().hexpand(true).halign(gtk4::Align::Start).build();
        let clear = gtk4::Button::with_label(&crate::tr!("Clear filter"));
        controls.append(&status);
        controls.append(&clear);
        let view = Self(Rc::new(RefCell::new(LocalResultViewState {
            result,
            store: None,
            selection: None,
            filter: None,
            sort: None,
            controls,
            status,
        })));
        let weak_view = Rc::downgrade(&view.0);
        clear.connect_clicked(move |_| {
            if let Some(view) = weak_view.upgrade() {
                Self(view).clear_filter();
            }
        });
        view
    }

    pub(crate) fn controls(&self) -> gtk4::Box {
        self.0.borrow().controls.clone()
    }

    pub(crate) fn attach(&self, store: RowStore, selection: gtk4::MultiSelection) {
        let mut state = self.0.borrow_mut();
        state.store = Some(store);
        state.selection = Some(selection);
        update_status(&state);
    }

    pub(crate) fn filter_by_value(&self, column: usize, value: Value) {
        if self.0.borrow().result.rows.iter().any(|row| row.get(column).is_some()) {
            self.0.borrow_mut().filter = Some((column, value));
            self.rebuild_visible_rows();
        }
    }

    pub(crate) fn clear_filter(&self) {
        self.0.borrow_mut().filter = None;
        self.rebuild_visible_rows();
    }

    pub(crate) fn sort_by(&self, column: usize, ascending: bool) {
        let result = self.0.borrow().result.clone();
        if local_sort::is_sortable_column(&result, column) {
            self.0.borrow_mut().sort = Some((column, ascending));
            self.rebuild_visible_rows();
        }
    }

    fn rebuild_visible_rows(&self) {
        let (result, store, selection, filter, sort) = {
            let state = self.0.borrow();
            let Some(store) = state.store.clone() else { return };
            let Some(selection) = state.selection.clone() else {
                return;
            };
            (state.result.clone(), store, selection, state.filter.clone(), state.sort)
        };
        let selected = selected_source_rows(&store, &selection);
        let mut order = match sort {
            Some((column, ascending)) => local_sort::sorted_source_indices(&result, column, ascending)
                .unwrap_or_else(|| (0..result.rows.len()).collect()),
            None => (0..result.rows.len()).collect(),
        };
        if let Some((column, value)) = filter {
            order.retain(|source_index| {
                result
                    .rows
                    .get(*source_index)
                    .and_then(|row| row.get(column))
                    .is_some_and(|candidate| same_filter_value(candidate, &value))
            });
        }
        if !store.replace_source_rows(&order) {
            return;
        }
        selection.unselect_all();
        for (position, source_index) in order.iter().enumerate() {
            if selected.contains(source_index) {
                selection.select_item(position as u32, false);
            }
        }
        update_status(&self.0.borrow());
    }
}

fn selected_source_rows(store: &RowStore, selection: &gtk4::MultiSelection) -> std::collections::HashSet<usize> {
    (0..selection.n_items())
        .filter(|position| selection.is_selected(*position))
        .filter_map(|position| store.source_index_at(position))
        .collect()
}

fn update_status(state: &LocalResultViewState) {
    if state.filter.is_none() {
        state.controls.set_visible(false);
        return;
    }
    let visible = state.store.as_ref().map_or(0, |store| store.n_items());
    let visible_text = visible.to_string();
    let loaded_text = state.result.rows.len().to_string();
    let mut summary = crate::tr!("Showing {visible} of {loaded} loaded rows")
        .replace("{visible}", &visible_text)
        .replace("{loaded}", &loaded_text);
    if state.result.truncated {
        state.status.add_css_class("warning");
        summary.push_str(" · ");
        summary.push_str(&crate::tr!("result truncated"));
    } else {
        state.status.remove_css_class("warning");
    }
    state.status.set_text(&summary);
    state.controls.set_visible(true);
}

fn same_filter_value(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Float(left), Value::Float(right)) => left == right || (left.is_nan() && right.is_nan()),
        _ => left == right,
    }
}

#[cfg(test)]
fn matching_source_indices(result: &QueryResult, column: usize, value: &Value) -> Vec<usize> {
    result
        .rows
        .iter()
        .enumerate()
        .filter_map(|(index, row)| {
            row.get(column)
                .is_some_and(|candidate| same_filter_value(candidate, value))
                .then_some(index)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use gtk4::prelude::*;
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    use super::{LocalResultView, matching_source_indices};

    fn result(values: Vec<Value>) -> QueryResult {
        QueryResult {
            columns: vec![ColumnInfo {
                name: "value".into(),
                data_type: "".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: values.into_iter().map(|value| vec![value]).collect(),
            truncated: false,
        }
    }

    #[test]
    fn local_value_filter_matches_native_values_without_display_coercion() {
        let result = result(vec![
            Value::Text("1".into()),
            Value::Int(1),
            Value::Null,
            Value::Text("NULL".into()),
        ]);

        assert_eq!(matching_source_indices(&result, 0, &Value::Int(1)), vec![1]);
        assert_eq!(matching_source_indices(&result, 0, &Value::Null), vec![2]);
    }

    #[test]
    fn local_value_filter_preserves_duplicate_source_order_and_ignores_missing_cells() {
        let mut result = result(vec![Value::Int(7), Value::Int(2), Value::Int(7)]);
        result.rows[1].clear();

        assert_eq!(matching_source_indices(&result, 0, &Value::Int(7)), vec![0, 2]);
        assert!(matching_source_indices(&result, 1, &Value::Int(7)).is_empty());
    }

    #[test]
    fn local_value_filter_distinguishes_sql_null_from_json_null() {
        let result = result(vec![Value::Null, Value::Json(serde_json::Value::Null)]);

        assert_eq!(matching_source_indices(&result, 0, &Value::Null), vec![0]);
        assert_eq!(
            matching_source_indices(&result, 0, &Value::Json(serde_json::Value::Null)),
            vec![1]
        );
    }

    #[test]
    fn local_value_filter_matches_nan_without_formatting_or_coercion() {
        let result = result(vec![Value::Float(f64::NAN), Value::Float(1.0)]);

        assert_eq!(matching_source_indices(&result, 0, &Value::Float(f64::NAN)), vec![0]);
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn local_filter_and_sort_keep_selection_attached_to_the_source_row() {
        gtk4::init().unwrap();
        let mut result = result(vec![Value::Int(3), Value::Int(1), Value::Int(2), Value::Int(2)]);
        result.truncated = true;
        let result = Arc::new(result);
        let store = crate::ui::row_store::RowStore::from_shared(result.clone());
        let selection = gtk4::MultiSelection::new(Some(store.clone()));
        selection.select_item(2, true);
        let view = LocalResultView::new(result);
        view.attach(store.clone(), selection.clone());
        assert!(!view.0.borrow().controls.is_visible());

        view.filter_by_value(0, Value::Int(2));
        view.sort_by(0, false);

        assert_eq!(
            (0..store.n_items())
                .map(|position| store.source_index_at(position))
                .collect::<Vec<_>>(),
            vec![Some(2), Some(3)]
        );
        let selected = selection.selection();
        assert_eq!(selected.size(), 1);
        assert_eq!(store.source_index_at(selected.nth(0)), Some(2));
        let state = view.0.borrow();
        assert!(state.controls.is_visible());
        assert!(state.status.has_css_class("warning"));
        drop(state);

        view.clear_filter();

        assert_eq!(store.n_items(), 4);
        assert_eq!(store.source_index_at(selection.selection().nth(0)), Some(2));
        assert!(!view.0.borrow().controls.is_visible());
    }
}
