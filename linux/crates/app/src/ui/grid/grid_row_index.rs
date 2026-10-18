use std::collections::HashMap;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;

use super::RowObject;
use crate::services::change_tracker::RowKey;

/// The grid's rows by the key the tracker files their changes under,
/// drafts included. The store owns the rows, so a row it drops is
/// forgotten here on the next lookup.
#[derive(Debug, Default)]
pub struct GridRowIndex(HashMap<RowKey, glib::WeakRef<RowObject>>);

impl GridRowIndex {
    pub fn rebuild(&mut self, store: &gio::ListStore) {
        self.0.clear();
        for position in 0..store.n_items() {
            if let Some(row) = store.item(position).and_downcast::<RowObject>() {
                self.insert(&row);
            }
        }
    }

    pub fn insert(&mut self, row: &RowObject) {
        if let Some(key) = row.id().tracker_key() {
            self.0.insert(key, row.downgrade());
        }
    }

    pub fn remove(&mut self, key: &RowKey) {
        self.0.remove(key);
    }

    pub fn get(&mut self, key: &RowKey) -> Option<RowObject> {
        let row = self.0.get(key)?.upgrade();
        if row.is_none() {
            self.0.remove(key);
        }
        row
    }

    pub fn position_in(&mut self, store: &gio::ListStore, key: &RowKey) -> Option<u32> {
        store.find(&self.get(key)?)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.0.len()
    }
}

#[cfg(test)]
mod tests {
    use gtk4::gio;
    use tablepro_core::Value;

    use super::GridRowIndex;
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::RowObject;

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn saved(id: i64) -> RowObject {
        RowObject::persisted(Some(key(id)), vec![Value::Int(id)].into())
    }

    #[test]
    fn grid_row_index_drops_dead_rows_on_get() {
        let mut index = GridRowIndex::default();
        let kept = saved(1);
        index.insert(&kept);
        index.insert(&saved(2));

        assert_eq!(index.get(&key(1)), Some(kept));
        assert_eq!(index.get(&key(2)), None, "a row nothing holds came back");
        assert_eq!(index.len(), 1, "the dead row stayed in the index");
    }

    #[test]
    fn drafts_are_found_by_their_draft_key_and_unkeyed_rows_not_at_all() {
        let store = gio::ListStore::new::<RowObject>();
        store.append(&RowObject::draft(7));
        store.append(&saved(1));
        store.append(&RowObject::persisted(None, vec![Value::Int(3)].into()));
        let mut index = GridRowIndex::default();

        index.rebuild(&store);

        assert_eq!(index.position_in(&store, &RowKey::Draft(7)), Some(0));
        assert_eq!(index.position_in(&store, &key(1)), Some(1));
        assert_eq!(index.len(), 2);
        index.remove(&RowKey::Draft(7));
        assert_eq!(index.get(&RowKey::Draft(7)), None);
    }

    #[test]
    fn a_draft_is_never_taken_for_a_saved_row_with_the_same_number() {
        let mut index = GridRowIndex::default();
        let draft = RowObject::draft(3);
        let row = saved(3);
        index.insert(&draft);
        index.insert(&row);

        assert_eq!(index.get(&RowKey::Draft(3)), Some(draft));
        assert_eq!(index.get(&key(3)), Some(row));
    }
}
