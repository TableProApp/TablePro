use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::{QueryResult, Value};

use crate::ui::row_store::RowStore;

use super::local_sort;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct ResultViewKey {
    pub(crate) statement_identity: crate::ui::editor::StatementIdentity,
    pub(crate) result_set_index: usize,
}

#[derive(Clone, Default)]
pub(crate) struct LocalResultSettingsStore(Rc<RefCell<HashMap<ResultViewKey, LocalResultSettings>>>);

#[derive(Clone, Default)]
pub(crate) struct LocalResultSettings {
    pub(crate) filter: Option<(usize, Value)>,
    pub(crate) sort: Option<(usize, bool)>,
    selection: Option<(std::sync::Weak<QueryResult>, HashSet<usize>)>,
}

impl LocalResultSettingsStore {
    fn get(&self, key: ResultViewKey) -> LocalResultSettings {
        self.0.borrow().get(&key).cloned().unwrap_or_default()
    }

    pub(crate) fn update(&self, key: ResultViewKey, update: impl FnOnce(&mut LocalResultSettings)) {
        update(self.0.borrow_mut().entry(key).or_default());
    }

    pub(crate) fn retain(&self, keys: &HashSet<ResultViewKey>) {
        self.0.borrow_mut().retain(|key, _| keys.contains(key));
    }

    fn selection_for(&self, key: ResultViewKey, result: &Arc<QueryResult>) -> Option<HashSet<usize>> {
        let state = self.0.borrow();
        let (saved_result, selected) = state.get(&key)?.selection.as_ref()?;
        let saved_result = saved_result.upgrade()?;
        Arc::ptr_eq(&saved_result, result).then(|| selected.clone())
    }
}

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
    clear_button: gtk4::Button,
    settings_store: LocalResultSettingsStore,
    settings_key: ResultViewKey,
    selection_syncing: Rc<Cell<bool>>,
}

impl LocalResultView {
    pub(crate) fn new(
        result: Arc<QueryResult>,
        settings_store: LocalResultSettingsStore,
        settings_key: ResultViewKey,
    ) -> Self {
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
        let settings = settings_store.get(settings_key);
        let view = Self(Rc::new(RefCell::new(LocalResultViewState {
            result,
            store: None,
            selection: None,
            filter: settings.filter,
            sort: settings.sort,
            controls,
            status,
            clear_button: clear.clone(),
            settings_store,
            settings_key,
            selection_syncing: Rc::new(Cell::new(false)),
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
        let (result, settings_store, settings_key, selection_syncing) = {
            let state = self.0.borrow();
            (
                state.result.clone(),
                state.settings_store.clone(),
                state.settings_key,
                state.selection_syncing.clone(),
            )
        };
        {
            let mut state = self.0.borrow_mut();
            state.store = Some(store.clone());
            state.selection = Some(selection.clone());
            update_status(&state);
        }
        self.rebuild_visible_rows();
        if let Some(selected) = settings_store.selection_for(settings_key, &result) {
            selection_syncing.set(true);
            let positions = gtk4::Bitset::new_empty();
            for position in 0..store.n_items() {
                if store
                    .source_index_at(position)
                    .is_some_and(|source| selected.contains(&source))
                {
                    positions.add(position);
                }
            }
            selection.set_selection(&positions, &gtk4::Bitset::new_range(0, store.n_items()));
            selection_syncing.set(false);
        }
        selection.connect_selection_changed(move |selection, _, _| {
            if selection_syncing.get() {
                return;
            }
            let selected = selected_source_rows(&store, selection);
            settings_store.update(settings_key, |settings| {
                settings.selection = Some((Arc::downgrade(&result), selected));
            });
        });
    }

    pub(crate) fn filter_by_value(&self, column: usize, value: Value) {
        if self.0.borrow().result.rows.iter().any(|row| row.get(column).is_some()) {
            self.0.borrow_mut().filter = Some((column, value));
            self.persist_settings();
            self.rebuild_visible_rows();
        }
    }

    pub(crate) fn clear_filter(&self) {
        self.0.borrow_mut().filter = None;
        self.persist_settings();
        self.rebuild_visible_rows();
    }

    pub(crate) fn sort_by(&self, column: usize, ascending: bool) {
        let result = self.0.borrow().result.clone();
        if local_sort::is_sortable_column(&result, column) {
            self.0.borrow_mut().sort = Some((column, ascending));
            self.persist_settings();
            self.rebuild_visible_rows();
        }
    }

    fn persist_settings(&self) {
        let state = self.0.borrow();
        state.settings_store.update(state.settings_key, |settings| {
            settings.filter = state.filter.clone();
            settings.sort = state.sort;
        });
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
        let syncing = self.0.borrow().selection_syncing.clone();
        syncing.set(true);
        if !store.replace_source_rows(&order) {
            syncing.set(false);
            return;
        }
        let positions = gtk4::Bitset::new_empty();
        for (position, source_index) in order.iter().enumerate() {
            if selected.contains(source_index) {
                positions.add(position as u32);
            }
        }
        selection.set_selection(&positions, &gtk4::Bitset::new_range(0, order.len() as u32));
        syncing.set(false);
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
        let sorted_truncated = state.sort.is_some() && state.result.truncated;
        state.clear_button.set_visible(false);
        state.controls.set_visible(sorted_truncated);
        if sorted_truncated {
            state.status.add_css_class("warning");
            state.status.set_text(&crate::tr!(
                "Sorted the loaded rows only; the result is truncated. Use ORDER BY for the full result."
            ));
        }
        return;
    }
    state.clear_button.set_visible(true);
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

    use super::{LocalResultSettingsStore, LocalResultView, ResultViewKey, matching_source_indices};

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
    fn local_result_settings_survive_rerender_and_are_pruned_when_no_longer_visible() {
        let settings = LocalResultSettingsStore::default();
        let key = ResultViewKey {
            statement_identity: crate::ui::editor::StatementIdentity {
                statement_index: 1,
                digest: [7; 32],
            },
            result_set_index: 0,
        };
        let second_set = ResultViewKey {
            result_set_index: 1,
            ..key
        };
        settings.update(key, |current| current.sort = Some((2, false)));
        settings.update(second_set, |current| current.sort = Some((0, true)));

        assert_eq!(settings.get(key).sort, Some((2, false)));
        settings.retain(&std::collections::HashSet::from([second_set]));
        assert_eq!(settings.get(key).sort, None);
        assert_eq!(settings.get(second_set).sort, Some((0, true)));
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
        let settings_store = LocalResultSettingsStore::default();
        let key = ResultViewKey {
            statement_identity: crate::ui::editor::StatementIdentity {
                statement_index: 0,
                digest: [1; 32],
            },
            result_set_index: 0,
        };
        let view = LocalResultView::new(result.clone(), settings_store.clone(), key);
        view.attach(store.clone(), selection.clone());
        assert!(!view.0.borrow().controls.is_visible());
        selection.select_item(2, true);

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

        let rerun_store = crate::ui::row_store::RowStore::from_shared(result.clone());
        let rerun_selection = gtk4::MultiSelection::new(Some(rerun_store.clone()));
        let rerun_view = LocalResultView::new(result.clone(), settings_store.clone(), key);
        rerun_view.attach(rerun_store.clone(), rerun_selection.clone());
        assert_eq!(rerun_store.n_items(), 2);
        assert_eq!(rerun_selection.selection().size(), 1);
        assert_eq!(rerun_store.source_index_at(rerun_selection.selection().nth(0)), Some(2));
        assert!(rerun_view.0.borrow().controls.is_visible());

        view.clear_filter();

        assert_eq!(store.n_items(), 4);
        assert_eq!(store.source_index_at(selection.selection().nth(0)), Some(2));
        let state = view.0.borrow();
        assert!(
            state.controls.is_visible(),
            "the sort of a truncated result keeps its notice"
        );
        assert!(!state.clear_button.is_visible());
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn filtering_a_fully_selected_result_restores_the_selection_in_one_signal() {
        gtk4::init().unwrap();
        let result = Arc::new(result((0..2000_i64).map(|value| Value::Int(value % 2)).collect()));
        let store = crate::ui::row_store::RowStore::from_shared(result.clone());
        let selection = gtk4::MultiSelection::new(Some(store.clone()));
        let key = ResultViewKey {
            statement_identity: crate::ui::editor::StatementIdentity {
                statement_index: 0,
                digest: [2; 32],
            },
            result_set_index: 0,
        };
        let view = LocalResultView::new(result.clone(), LocalResultSettingsStore::default(), key);
        view.attach(store.clone(), selection.clone());
        selection.select_all();
        let emissions = std::rc::Rc::new(std::cell::Cell::new(0_u32));
        let counter = emissions.clone();
        selection.connect_selection_changed(move |_, _, _| counter.set(counter.get() + 1));

        view.filter_by_value(0, Value::Int(1));

        assert_eq!(store.n_items(), 1000);
        assert_eq!(selection.selection().size(), 1000);
        assert!(emissions.get() <= 2, "{} selection-changed emissions", emissions.get());
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn sorting_a_truncated_result_without_a_filter_warns_that_only_loaded_rows_were_sorted() {
        gtk4::init().unwrap();
        let mut loaded = result(vec![Value::Int(3), Value::Int(1), Value::Int(2)]);
        loaded.truncated = true;
        let loaded = Arc::new(loaded);
        let store = crate::ui::row_store::RowStore::from_shared(loaded.clone());
        let selection = gtk4::MultiSelection::new(Some(store.clone()));
        let key = ResultViewKey {
            statement_identity: crate::ui::editor::StatementIdentity {
                statement_index: 0,
                digest: [2; 32],
            },
            result_set_index: 0,
        };
        let view = LocalResultView::new(loaded.clone(), LocalResultSettingsStore::default(), key);
        view.attach(store, selection);
        assert!(!view.0.borrow().controls.is_visible());

        view.sort_by(0, false);

        let state = view.0.borrow();
        assert!(state.controls.is_visible());
        assert!(state.status.has_css_class("warning"));
        assert!(!state.clear_button.is_visible());
        drop(state);

        let complete = Arc::new(result(vec![Value::Int(3), Value::Int(1)]));
        let complete_store = crate::ui::row_store::RowStore::from_shared(complete.clone());
        let complete_selection = gtk4::MultiSelection::new(Some(complete_store.clone()));
        let complete_view = LocalResultView::new(complete, LocalResultSettingsStore::default(), key);
        complete_view.attach(complete_store, complete_selection);
        complete_view.sort_by(0, true);
        assert!(!complete_view.0.borrow().controls.is_visible());
    }
}
