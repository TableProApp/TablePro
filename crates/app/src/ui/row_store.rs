use std::cell::RefCell;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use std::sync::Arc;

use tablepro_core::QueryResult;

use super::row_object::RowObject;

pub(super) enum Slot {
    /// A row that has not yet been requested from the shared result.
    Shared(usize),
    /// A weak cache for a shared row. The source index recreates it after
    /// the view and every other consumer release the current RowObject.
    Cached {
        source_index: usize,
        object: glib::WeakRef<RowObject>,
    },
    /// Drafts and replacement rows have no immutable source row to rebuild
    /// from, so the model remains their owner.
    Object(RowObject),
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct RowStore {
        pub(in crate::ui) slots: RefCell<Vec<Slot>>,
        pub(in crate::ui) source: RefCell<Option<Arc<QueryResult>>>,
        pub(in crate::ui) projection: RefCell<Option<(Vec<usize>, usize)>>,
        pub(in crate::ui) preview_keys: RefCell<Vec<usize>>,
        pub(in crate::ui) preview_redis_strings: std::cell::Cell<bool>,
        pub(in crate::ui) preview_from_result: std::cell::Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for RowStore {
        const NAME: &str = "TableProRowStore";
        type Type = super::RowStore;
        type Interfaces = (gio::ListModel,);
    }

    impl ObjectImpl for RowStore {
        fn dispose(&self) {
            self.obj().detach_cached_rows();
        }
    }

    impl ListModelImpl for RowStore {
        fn item_type(&self) -> glib::Type {
            RowObject::static_type()
        }

        fn n_items(&self) -> u32 {
            self.slots.borrow().len() as u32
        }

        fn item(&self, position: u32) -> Option<glib::Object> {
            let mut slots = self.slots.borrow_mut();
            let slot = slots.get_mut(position as usize)?;
            match slot {
                Slot::Shared(index) => {
                    let source_index = *index;
                    let source = self.source.borrow();
                    let result = source.as_ref()?;
                    let projection = self.projection.borrow();
                    let row = row_for_source(
                        result,
                        source_index,
                        projection.as_ref(),
                        &self.preview_keys.borrow(),
                        self.preview_redis_strings.get(),
                        self.preview_from_result.get(),
                    )?;
                    let object = glib::WeakRef::new();
                    object.set(Some(&row));
                    *slot = Slot::Cached { source_index, object };
                    Some(row.upcast())
                }
                Slot::Cached { source_index, object } => {
                    if let Some(row) = object.upgrade() {
                        Some(row.upcast())
                    } else {
                        let source_index = *source_index;
                        let source = self.source.borrow();
                        let result = source.as_ref()?;
                        let projection = self.projection.borrow();
                        let row = row_for_source(
                            result,
                            source_index,
                            projection.as_ref(),
                            &self.preview_keys.borrow(),
                            self.preview_redis_strings.get(),
                            self.preview_from_result.get(),
                        )?;
                        object.set(Some(&row));
                        Some(row.upcast())
                    }
                }
                Slot::Object(object) => Some(object.clone().upcast()),
            }
        }
    }
}

fn row_for_source(
    result: &Arc<QueryResult>,
    source_index: usize,
    projection: Option<&(Vec<usize>, usize)>,
    preview_keys: &[usize],
    preview_redis_strings: bool,
    preview_from_result: bool,
) -> Option<RowObject> {
    let row = RowObject::from_shared(result, source_index, projection.cloned())?;
    if preview_from_result {
        row.preview_values_from_result();
    } else if preview_redis_strings {
        row.preview_long_redis_string_values(preview_keys);
    } else {
        row.preview_long_values(preview_keys);
    }
    Some(row)
}

fn valid_projection(result: &QueryResult, indices: &[usize], width: usize) -> bool {
    (indices.len() == result.columns.len() || (result.columns.is_empty() && result.rows.is_empty()))
        && indices.iter().all(|index| *index < width)
        && indices.iter().copied().collect::<std::collections::HashSet<_>>().len() == indices.len()
        && result.rows.iter().all(|row| row.len() == indices.len())
}

glib::wrapper! {
    pub struct RowStore(ObjectSubclass<imp::RowStore>) @implements gio::ListModel;
}

impl RowStore {
    pub fn cells_for_search(&self, position: u32) -> Option<Vec<Option<tablepro_core::Value>>> {
        let slots = self.imp().slots.borrow();
        match slots.get(position as usize)? {
            Slot::Object(row) => Some(row.loaded_cells()),
            Slot::Shared(source_index) => self.source_cells(*source_index),
            Slot::Cached { source_index, object } => {
                let mut source = self.source_cells(*source_index)?;
                if let Some(row) = object.upgrade() {
                    for (index, value) in row.loaded_cells().into_iter().enumerate() {
                        if row.cell_preview(index).is_none() && value.is_some() {
                            source[index] = value;
                        }
                    }
                }
                Some(source)
            }
        }
    }

    fn source_cells(&self, source_index: usize) -> Option<Vec<Option<tablepro_core::Value>>> {
        let source = self.imp().source.borrow();
        let cells = source.as_ref()?.rows.get(source_index)?;
        let projection = self.imp().projection.borrow();
        Some(match projection.as_ref() {
            Some((indices, width)) => {
                let mut values = vec![None; *width];
                for (index, value) in indices.iter().copied().zip(cells) {
                    values[index] = Some(value.clone());
                }
                values
            }
            None => cells.iter().cloned().map(Some).collect(),
        })
    }

    pub fn from_shared(result: Arc<QueryResult>) -> Self {
        let store: Self = glib::Object::new();
        store.install_shared(result, None, Vec::new());
        store
    }

    pub fn from_shared_with_previews(result: Arc<QueryResult>, key_indices: Vec<usize>) -> Self {
        let store: Self = glib::Object::new();
        store.install_shared(result, None, key_indices);
        store
    }

    pub fn from_shared_with_result_previews(result: Arc<QueryResult>) -> Self {
        let store: Self = glib::Object::new();
        store.install_shared(result, None, Vec::new());
        store.imp().preview_from_result.set(true);
        store
    }

    pub fn from_shared_with_redis_string_previews(result: Arc<QueryResult>, key_indices: Vec<usize>) -> Self {
        let store: Self = glib::Object::new();
        store.install_shared(result, None, key_indices);
        store.imp().preview_redis_strings.set(true);
        store
    }

    pub fn from_projected(result: Arc<QueryResult>, indices: Vec<usize>, width: usize) -> Result<Self, String> {
        if !valid_projection(&result, &indices, width) {
            return Err("projected browse result does not match its schema mapping".into());
        }
        let store: Self = glib::Object::new();
        store.install_shared(result, Some((indices, width)), Vec::new());
        Ok(store)
    }

    pub fn from_projected_with_previews(
        result: Arc<QueryResult>,
        indices: Vec<usize>,
        width: usize,
        key_indices: Vec<usize>,
    ) -> Result<Self, String> {
        if !valid_projection(&result, &indices, width) {
            return Err("projected browse result does not match its schema mapping".into());
        }
        let store: Self = glib::Object::new();
        store.install_shared(result, Some((indices, width)), key_indices);
        Ok(store)
    }

    pub fn from_projected_with_redis_string_previews(
        result: Arc<QueryResult>,
        indices: Vec<usize>,
        width: usize,
        key_indices: Vec<usize>,
    ) -> Result<Self, String> {
        let store = Self::from_projected_with_previews(result, indices, width, key_indices)?;
        store.imp().preview_redis_strings.set(true);
        Ok(store)
    }

    pub fn replace_shared(&self, result: Arc<QueryResult>) {
        self.replace_shared_with_previews(result, Vec::new());
    }

    pub fn replace_shared_with_previews(&self, result: Arc<QueryResult>, key_indices: Vec<usize>) {
        let removed = self.n_items();
        self.install_shared(result, None, key_indices);
        self.items_changed(0, removed, self.n_items());
    }

    pub fn replace_shared_with_redis_string_previews(&self, result: Arc<QueryResult>, key_indices: Vec<usize>) {
        let removed = self.n_items();
        self.install_shared(result, None, key_indices);
        self.imp().preview_redis_strings.set(true);
        self.items_changed(0, removed, self.n_items());
    }

    pub fn replace_projected(&self, result: Arc<QueryResult>, indices: Vec<usize>, width: usize) -> Result<(), String> {
        self.replace_projected_with_previews(result, indices, width, Vec::new())
    }

    pub fn replace_projected_with_previews(
        &self,
        result: Arc<QueryResult>,
        indices: Vec<usize>,
        width: usize,
        key_indices: Vec<usize>,
    ) -> Result<(), String> {
        if !valid_projection(&result, &indices, width) {
            return Err("projected browse result does not match its schema mapping".into());
        }
        let removed = self.n_items();
        self.install_shared(result, Some((indices, width)), key_indices);
        self.items_changed(0, removed, self.n_items());
        Ok(())
    }

    pub fn replace_projected_with_redis_string_previews(
        &self,
        result: Arc<QueryResult>,
        indices: Vec<usize>,
        width: usize,
        key_indices: Vec<usize>,
    ) -> Result<(), String> {
        self.replace_projected_with_previews(result, indices, width, key_indices)?;
        self.imp().preview_redis_strings.set(true);
        Ok(())
    }

    fn install_shared(
        &self,
        result: Arc<QueryResult>,
        projection: Option<(Vec<usize>, usize)>,
        preview_keys: Vec<usize>,
    ) {
        self.detach_cached_rows();
        *self.imp().slots.borrow_mut() = (0..result.rows.len()).map(Slot::Shared).collect();
        *self.imp().source.borrow_mut() = Some(result);
        *self.imp().projection.borrow_mut() = projection;
        *self.imp().preview_keys.borrow_mut() = preview_keys;
        self.imp().preview_redis_strings.set(false);
        self.imp().preview_from_result.set(false);
    }

    fn detach_cached_rows(&self) {
        for slot in self.imp().slots.borrow().iter() {
            match slot {
                Slot::Cached { object, .. } => {
                    if let Some(row) = object.upgrade() {
                        row.detach_shared();
                    }
                }
                Slot::Object(row) => row.detach_shared(),
                Slot::Shared(_) => {}
            }
        }
    }

    pub fn source_value_at(&self, position: u32, column: usize) -> Option<tablepro_core::Value> {
        let source_index = {
            let slots = self.imp().slots.borrow();
            match slots.get(position as usize)? {
                Slot::Shared(index)
                | Slot::Cached {
                    source_index: index, ..
                } => *index,
                Slot::Object(_) => return None,
            }
        };
        self.source_cells(source_index)?.get(column)?.clone()
    }

    pub fn insert(&self, position: u32, row: &RowObject) {
        self.splice(position, 0, std::slice::from_ref(row));
    }

    pub fn remove(&self, position: u32) {
        self.splice(position, 1, &[]);
    }

    pub fn splice(&self, position: u32, removals: u32, additions: &[RowObject]) {
        let removed = {
            let mut slots = self.imp().slots.borrow_mut();
            let start = (position as usize).min(slots.len());
            let end = (start + removals as usize).min(slots.len());
            let replacement = additions.iter().cloned().map(Slot::Object);
            slots.splice(start..end, replacement);
            (end - start) as u32
        };
        self.items_changed(position, removed, additions.len() as u32);
    }

    pub fn find(&self, row: &RowObject) -> Option<u32> {
        let slots = self.imp().slots.borrow();
        let position = slots.iter().position(|slot| match slot {
            Slot::Object(object) => object == row,
            Slot::Cached { object, .. } => object.upgrade().is_some_and(|cached| cached == *row),
            Slot::Shared(_) => false,
        })?;
        Some(position as u32)
    }

    #[cfg(test)]
    fn materialized(&self) -> usize {
        let slots = self.imp().slots.borrow();
        slots
            .iter()
            .filter(|slot| match slot {
                Slot::Object(_) => true,
                Slot::Cached { object, .. } => object.upgrade().is_some(),
                Slot::Shared(_) => false,
            })
            .count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;
    use tablepro_core::Value;

    fn rows(count: i64) -> Vec<Vec<Value>> {
        (0..count).map(|n| vec![Value::Int(n)]).collect()
    }

    fn first_cell(store: &RowStore, position: u32) -> Value {
        let row = store.item(position).and_downcast::<RowObject>();
        row.map(|row| row.cell_value(0)).unwrap_or(Value::Null)
    }

    #[test]
    fn no_row_object_exists_until_a_row_is_requested() {
        let store = RowStore::from_shared(shared(1000));
        assert_eq!(store.n_items(), 1000);
        assert_eq!(store.materialized(), 0);
        let row = store.item(41).and_downcast::<RowObject>().unwrap();
        assert_eq!(row.cell_value(0), Value::Int(41));
        assert_eq!(store.materialized(), 1);
        drop(row);
        assert_eq!(store.materialized(), 0);
        assert_eq!(first_cell(&store, 41), Value::Int(41));
        assert_eq!(store.materialized(), 0);
    }

    #[test]
    fn a_requested_row_keeps_its_identity_and_its_edits() {
        let store = RowStore::from_shared(shared(3));
        let first = store.item(1).and_downcast::<RowObject>().unwrap();
        first.set_cell(0, Value::Int(99));
        let again = store.item(1).and_downcast::<RowObject>().unwrap();
        assert_eq!(first, again);
        assert_eq!(again.cell_value(0), Value::Int(99));
        assert_eq!(store.find(&again), Some(1));
    }

    #[test]
    fn a_released_clean_row_can_be_recreated_from_the_shared_result() {
        let store = RowStore::from_shared(shared(3));
        let first = store.item(1).and_downcast::<RowObject>().unwrap();
        let held_identity = first.clone();
        assert_eq!(store.materialized(), 1);
        drop(first);

        let again = store.item(1).and_downcast::<RowObject>().unwrap();
        assert_eq!(again, held_identity);
        assert_eq!(again.cell_value(0), Value::Int(1));
        assert_eq!(store.materialized(), 1);
        drop(held_identity);
        assert_eq!(store.materialized(), 1);
        drop(again);
        assert_eq!(store.materialized(), 0);

        let recreated = store.item(1).and_downcast::<RowObject>().unwrap();
        assert_eq!(recreated.cell_value(0), Value::Int(1));
        assert_eq!(store.materialized(), 1);
    }

    #[test]
    fn draft_rows_remain_owned_by_the_store() {
        let store = RowStore::from_shared(shared(1));
        let draft = RowObject::new_draft(7, vec![Value::Int(-1)]);
        store.insert(0, &draft);
        drop(draft);

        assert_eq!(store.materialized(), 1);
        let again = store.item(0).and_downcast::<RowObject>().unwrap();
        assert_eq!(again.draft_id(), Some(7));
        assert_eq!(again.cell_value(0), Value::Int(-1));
    }

    #[test]
    fn an_out_of_range_position_yields_nothing() {
        let store = RowStore::from_shared(shared(2));
        assert!(store.item(2).is_none());
    }

    #[test]
    fn insert_remove_and_splice_move_rows_and_report_the_change() {
        let store = RowStore::from_shared(shared(3));
        let changes = Rc::new(Cell::new((0, 0, 0)));
        let seen = changes.clone();
        store.connect_items_changed(move |_, position, removed, added| seen.set((position, removed, added)));

        store.insert(0, &RowObject::new_draft(7, vec![Value::Int(-1)]));
        assert_eq!(changes.get(), (0, 0, 1));
        assert_eq!(store.n_items(), 4);
        assert_eq!(first_cell(&store, 0), Value::Int(-1));
        assert_eq!(first_cell(&store, 1), Value::Int(0));

        store.remove(0);
        assert_eq!(changes.get(), (0, 1, 0));
        assert_eq!(first_cell(&store, 0), Value::Int(0));

        store.splice(1, 1, &[RowObject::new(vec![Value::Int(50)])]);
        assert_eq!(changes.get(), (1, 1, 1));
        assert_eq!(first_cell(&store, 1), Value::Int(50));
        assert_eq!(first_cell(&store, 2), Value::Int(2));
    }

    #[test]
    fn replacing_the_rows_reports_one_change_and_drops_old_objects() {
        let old = shared(4);
        let store = RowStore::from_shared(old.clone());
        let held = store.item(0).and_downcast::<RowObject>().unwrap();
        let changes = Rc::new(Cell::new((0, 0, 0)));
        let seen = changes.clone();
        store.connect_items_changed(move |_, position, removed, added| seen.set((position, removed, added)));

        store.replace_shared(shared(2));
        assert_eq!(changes.get(), (0, 4, 2));
        assert_eq!(store.n_items(), 2);
        assert_eq!(store.materialized(), 0);
        assert_eq!(store.find(&held), None);
        assert_eq!(held.cell_value(0), Value::Int(0));
        assert_eq!(Arc::strong_count(&old), 1);
    }

    #[test]
    fn replacing_shared_rows_preserves_edits_on_held_rows() {
        let old = shared(2);
        let store = RowStore::from_shared(old.clone());
        let held = store.item(0).and_downcast::<RowObject>().unwrap();
        held.set_cell(0, Value::Int(99));

        store.replace_shared(shared(1));

        assert_eq!(held.cell_value(0), Value::Int(99));
        assert_eq!(Arc::strong_count(&old), 1);
    }

    #[test]
    fn a_held_row_survives_store_disposal_without_retaining_the_result() {
        let result = shared(2);
        let store = RowStore::from_shared(result.clone());
        let held = store.item(1).and_downcast::<RowObject>().unwrap();

        drop(store);

        assert_eq!(held.cell_value(0), Value::Int(1));
        assert_eq!(Arc::strong_count(&result), 1);
    }

    #[test]
    fn a_handler_may_read_the_model_while_it_is_changing() {
        let store = RowStore::from_shared(shared(2));
        let reader = store.clone();
        store.connect_items_changed(move |_, _, _, _| {
            let _ = reader.item(0);
        });
        store.replace_shared(shared(3));
        store.remove(0);
        assert_eq!(store.n_items(), 2);
    }

    fn shared(count: i64) -> Arc<QueryResult> {
        Arc::new(QueryResult {
            columns: Vec::new(),
            rows: rows(count),
            truncated: false,
        })
    }

    #[test]
    fn a_shared_result_is_read_in_place_and_never_copied_up_front() {
        let result = shared(500);
        let store = RowStore::from_shared(result.clone());
        assert_eq!(store.n_items(), 500);
        assert_eq!(store.materialized(), 0);
        assert_eq!(Arc::strong_count(&result), 2);
        let row = store.item(499).and_downcast::<RowObject>().unwrap();
        assert_eq!(row.cell_value(0), Value::Int(499));
        assert_eq!(store.materialized(), 1);
    }

    #[test]
    fn shared_rows_survive_a_draft_inserted_above_them() {
        let store = RowStore::from_shared(shared(3));
        store.insert(0, &RowObject::new_draft(1, vec![Value::Int(-1)]));
        assert_eq!(first_cell(&store, 0), Value::Int(-1));
        assert_eq!(first_cell(&store, 3), Value::Int(2));
        store.remove(0);
        assert_eq!(first_cell(&store, 0), Value::Int(0));
    }

    #[test]
    fn replacing_a_shared_result_releases_the_old_one() {
        let old = shared(10);
        let store = RowStore::from_shared(old.clone());
        store.replace_shared(shared(2));
        assert_eq!(Arc::strong_count(&old), 1);
        assert_eq!(store.n_items(), 2);
    }

    #[test]
    fn projected_store_keeps_sql_null_distinct_from_an_unfetched_cell() {
        let result = Arc::new(QueryResult {
            columns: vec![column("id"), column("name")],
            rows: vec![vec![Value::Null, Value::Text("Ada".into())]],
            truncated: false,
        });
        let store = RowStore::from_projected(result.clone(), vec![0, 2], 3).unwrap();
        let row = store.item(0).and_downcast::<RowObject>().unwrap();

        assert!(row.cell_is_loaded(0));
        assert_eq!(row.cell_value(0), Value::Null);
        assert!(!row.cell_is_loaded(1));
        assert!(row.complete_cells().is_none());
        assert_eq!(row.cell_value(2), Value::Text("Ada".into()));

        store.replace_shared(shared(1));
        assert_eq!(row.cell_value(0), Value::Null);
        assert!(!row.cell_is_loaded(1));
        assert_eq!(row.cell_value(2), Value::Text("Ada".into()));
        assert_eq!(Arc::strong_count(&result), 1);
    }

    #[test]
    fn projected_browse_rows_preview_long_values_without_losing_the_key() {
        let text = "x".repeat(9000);
        let result = Arc::new(QueryResult {
            columns: vec![column("id"), column("payload")],
            rows: vec![vec![Value::Int(7), Value::Text(text.clone())]],
            truncated: false,
        });
        let store = RowStore::from_projected_with_previews(result, vec![0, 2], 3, vec![0]).unwrap();
        let row = store.item(0).and_downcast::<RowObject>().unwrap();

        assert_eq!(row.cell_value(0), Value::Int(7));
        assert!(row.cell_preview(2).is_some());
        assert!(!row.cell_is_loaded(1));
        assert_eq!(row.cell_value(2), Value::Text(text.clone()));
        assert_eq!(row.cell_preview(2).unwrap().byte_count, text.len());
        assert!(
            row.complete_cells().is_none(),
            "the projected hidden column is still unfetched"
        );
    }

    #[test]
    fn arbitrary_query_previews_can_recover_full_values_from_the_shared_result() {
        let text = "x".repeat(9000);
        let bytes = vec![7; 9000];
        let json = serde_json::json!({"payload": text});
        let result = Arc::new(QueryResult {
            columns: vec![column("id"), column("text"), column("bytes"), column("json")],
            rows: vec![vec![
                Value::Int(7),
                Value::Text("x".repeat(9000)),
                Value::Bytes(bytes.clone()),
                Value::Json(json.clone()),
            ]],
            truncated: false,
        });
        let store = RowStore::from_shared_with_result_previews(result);
        let row = store.item(0).and_downcast::<RowObject>().unwrap();

        assert_eq!(row.cell_value(0), Value::Int(7));
        assert_eq!(row.cell_preview(1).unwrap().byte_count, 9000);
        assert_eq!(row.cell_preview(2).unwrap().byte_count, bytes.len());
        assert!(row.cell_preview(3).unwrap().byte_count > 9000);
        assert_eq!(store.source_value_at(0, 1), Some(Value::Text("x".repeat(9000))));
        assert_eq!(store.source_value_at(0, 2), Some(Value::Bytes(bytes)));
        assert_eq!(store.source_value_at(0, 3), Some(Value::Json(json.clone())));
        assert_eq!(
            row.complete_cells(),
            Some(vec![
                Value::Int(7),
                Value::Text("x".repeat(9000)),
                Value::Bytes(vec![7; 9000]),
                Value::Json(json)
            ]),
            "copy, export and row JSON read the full values"
        );
    }

    #[test]
    fn redis_previews_only_string_values_and_preserves_keys_and_other_types() {
        let long = "x".repeat(9000);
        let result = Arc::new(QueryResult {
            columns: vec![column("Key"), column("Type"), column("TTL"), column("Value")],
            rows: vec![
                vec![
                    Value::Text("str-key".into()),
                    Value::Text("string".into()),
                    Value::Int(-1),
                    Value::Text(long.clone()),
                ],
                vec![
                    Value::Text("hash-key".into()),
                    Value::Text("hash".into()),
                    Value::Int(-1),
                    Value::Text(long.clone()),
                ],
            ],
            truncated: false,
        });
        let store = RowStore::from_shared_with_redis_string_previews(result, vec![0]);
        let string_row = store.item(0).and_downcast::<RowObject>().unwrap();
        let hash_row = store.item(1).and_downcast::<RowObject>().unwrap();
        assert_eq!(string_row.cell_value(0), Value::Text("str-key".into()));
        assert_eq!(string_row.cell_preview(3).unwrap().byte_count, long.len());
        assert_eq!(hash_row.cell_value(3), Value::Text(long));
        assert!(hash_row.cell_preview(3).is_none());
    }

    #[test]
    fn loaded_row_search_uses_full_shared_value_without_materializing_it_in_the_grid() {
        let text = "x".repeat(9000);
        let result = Arc::new(QueryResult {
            columns: vec![column("id"), column("payload")],
            rows: vec![vec![Value::Int(7), Value::Text(text.clone())]],
            truncated: false,
        });
        let store = RowStore::from_shared_with_previews(result, vec![0]);
        let row = store.item(0).and_downcast::<RowObject>().unwrap();

        assert!(row.cell_preview(1).is_some());
        assert_eq!(row.cell_value(1), Value::Text(text.clone()));
        assert_eq!(store.cells_for_search(0).unwrap()[1], Some(Value::Text(text)));
    }

    #[test]
    fn projected_store_refuses_rows_that_do_not_match_the_column_map() {
        let result = Arc::new(QueryResult {
            columns: vec![column("id")],
            rows: vec![vec![Value::Int(1), Value::Int(2)]],
            truncated: false,
        });
        assert!(RowStore::from_projected(result, vec![0], 1).is_err());
    }

    fn column(name: &str) -> tablepro_core::ColumnInfo {
        tablepro_core::ColumnInfo {
            name: name.into(),
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
        }
    }
}
