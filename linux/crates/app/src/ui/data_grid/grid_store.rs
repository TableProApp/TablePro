use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};

use gtk4::gio;
use gtk4::prelude::*;

use super::{GridRow, RowData};
use crate::services::change_tracker::RowKey;

/// The grid's rows: a list of stable slots and an index of them by
/// tracker key. Drafts sit on top, above the rows that were read.
#[derive(Debug)]
pub struct GridStore {
    list: gio::ListStore,
    index: RefCell<HashMap<RowKey, GridRow>>,
    drafts: Cell<u32>,
}

impl Default for GridStore {
    fn default() -> Self {
        Self {
            list: gio::ListStore::new::<GridRow>(),
            index: RefCell::default(),
            drafts: Cell::new(0),
        }
    }
}

impl GridStore {
    pub fn list(&self) -> &gio::ListStore {
        &self.list
    }

    pub fn len(&self) -> u32 {
        self.list.n_items()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn row(&self, position: u32) -> Option<GridRow> {
        self.list.item(position).and_downcast()
    }

    pub fn rows(&self) -> impl Iterator<Item = GridRow> + '_ {
        (0..self.len()).filter_map(|position| self.row(position))
    }

    /// The drafts on top of the rows that were read.
    pub fn draft_count(&self) -> u32 {
        self.drafts.get()
    }

    pub fn row_for(&self, key: &RowKey) -> Option<GridRow> {
        self.index.borrow().get(key).cloned()
    }

    pub fn position_of(&self, row: &GridRow) -> Option<u32> {
        self.list.find(row)
    }

    /// Write `rows` into the slots the store has and add or drop only the
    /// difference, so the rows GTK already built are kept.
    pub fn replace(&self, rows: Vec<RowData>) {
        let renumbered = self.count_drafts(&rows);
        let kept = self.len().min(rows.len() as u32) as usize;
        let mut rows = rows.into_iter();
        for (position, data) in rows.by_ref().take(kept).enumerate() {
            if let Some(row) = self.row(position as u32)
                && !row.set_data(data)
                && renumbered
            {
                row.bump_revision();
            }
        }
        let added: Vec<GridRow> = rows.map(GridRow::new).collect();
        match added.is_empty() {
            false => self.list.splice(self.len(), 0, &added),
            true if self.len() as usize > kept => {
                self.retire_from(kept as u32, self.len());
                self.list
                    .splice(kept as u32, self.len() - kept as u32, &[] as &[GridRow]);
            }
            true => {}
        }
        self.reindex();
    }

    /// New slots for every row, for a list a sort model reads.
    pub fn reset(&self, rows: Vec<RowData>) {
        self.count_drafts(&rows);
        let added: Vec<GridRow> = rows.into_iter().map(GridRow::new).collect();
        self.retire_from(0, self.len());
        self.list.splice(0, self.len(), &added);
        self.reindex();
    }

    pub fn append(&self, rows: Vec<RowData>) {
        let added: Vec<GridRow> = rows.into_iter().map(GridRow::new).collect();
        for row in &added {
            self.index_row(row);
        }
        self.list.splice(self.len(), 0, &added);
    }

    pub fn clear(&self) {
        self.drafts.set(0);
        self.retire_from(0, self.len());
        self.list.remove_all();
        self.index.borrow_mut().clear();
    }

    /// The tracker lists new drafts oldest first, and the newest goes on
    /// top. A paste can add thousands, so they go in as one change.
    pub fn insert_drafts(&self, draft_ids: &[u64]) {
        if draft_ids.is_empty() {
            return;
        }
        let rows: Vec<GridRow> = draft_ids
            .iter()
            .rev()
            .map(|draft_id| GridRow::new(RowData::draft(*draft_id)))
            .collect();
        for row in &rows {
            self.index_row(row);
        }
        self.drafts.set(self.drafts.get() + rows.len() as u32);
        self.list.splice(0, 0, &rows);
    }

    /// One change per run of removed rows rather than one per row, since
    /// an undo can take thousands of drafts away at once.
    pub fn remove_drafts(&self, draft_ids: &[u64]) {
        if draft_ids.is_empty() {
            return;
        }
        let removed: HashSet<u64> = draft_ids.iter().copied().collect();
        let is_removed = |position: u32| {
            self.row(position)
                .and_then(|row| row.draft_id())
                .is_some_and(|draft_id| removed.contains(&draft_id))
        };
        let left = self
            .rows()
            .filter_map(|row| row.draft_id())
            .filter(|draft_id| !removed.contains(draft_id))
            .count();
        self.drafts.set(left as u32);
        let mut position = self.len();
        while position > 0 {
            position -= 1;
            if !is_removed(position) {
                continue;
            }
            let end = position + 1;
            while position > 0 && is_removed(position - 1) {
                position -= 1;
            }
            self.retire_from(position, end);
            self.list.splice(position, end - position, &[] as &[GridRow]);
        }
        let mut index = self.index.borrow_mut();
        for draft_id in draft_ids {
            index.remove(&RowKey::Draft(*draft_id));
        }
    }

    /// The gutter numbers saved rows past the drafts, so the count moves
    /// before any row redraws. Says whether it moved.
    fn count_drafts(&self, rows: &[RowData]) -> bool {
        let drafts = rows.iter().filter(|row| row.id.draft_id().is_some()).count() as u32;
        self.drafts.replace(drafts) != drafts
    }

    fn retire_from(&self, start: u32, end: u32) {
        for position in start..end {
            if let Some(row) = self.row(position) {
                row.retire();
            }
        }
    }

    fn reindex(&self) {
        self.index.borrow_mut().clear();
        for row in self.rows() {
            self.index_row(&row);
        }
    }

    fn index_row(&self, row: &GridRow) {
        if let Some(key) = row.tracker_key() {
            self.index.borrow_mut().insert(key, row.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::sync::Arc;

    use tablepro_core::Value;

    use super::*;

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn saved(id: i64) -> RowData {
        RowData::persisted(Some(key(id)), Arc::from([Value::Int(id)]))
    }

    fn changes(store: &GridStore) -> Rc<RefCell<Vec<(u32, u32, u32)>>> {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        store.list().connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added))
        });
        seen
    }

    #[test]
    fn a_page_of_the_same_size_keeps_every_slot() {
        let store = GridStore::default();
        store.replace(vec![saved(1), saved(2)]);
        let first = store.row(0).expect("a row");
        let seen = changes(&store);

        store.replace(vec![saved(3), saved(4)]);

        assert!(seen.borrow().is_empty(), "no slot came or went");
        assert_eq!(store.row(0), Some(first));
        assert_eq!(store.row(0).and_then(|row| row.key()), Some(key(3)));
        assert_eq!(store.row_for(&key(4)).and_then(|row| store.position_of(&row)), Some(1));
        assert!(store.row_for(&key(1)).is_none());
    }

    #[test]
    fn a_shorter_or_longer_page_changes_only_the_tail() {
        let store = GridStore::default();
        store.replace(vec![saved(1), saved(2), saved(3)]);
        let seen = changes(&store);

        store.replace(vec![saved(4)]);
        store.replace(vec![saved(5), saved(6), saved(7), saved(8)]);

        assert_eq!(*seen.borrow(), [(1, 2, 0), (1, 0, 3)]);
        assert_eq!(store.len(), 4);
    }

    #[test]
    fn a_row_that_leaves_the_store_lets_go_of_its_pins() {
        let store = GridStore::default();
        let rows = vec![saved(1), saved(2), saved(3)];
        store.replace(rows.clone());
        let kept = store.row(0).expect("a row").pin();
        let dropped = store.row(2).expect("a row").pin();

        store.replace(rows[..2].to_vec());

        assert!(kept.is_current(), "a row the page kept lost its pin");
        assert!(!dropped.is_current(), "a row a shorter page dropped still resolves");
        store.insert_drafts(&[7]);
        let draft = store.row(0).expect("the draft").pin();
        store.remove_drafts(&[7]);
        assert!(!draft.is_current(), "a removed draft still resolves");
        store.clear();
        assert!(!kept.is_current(), "a cleared row still resolves");
    }

    #[test]
    fn every_row_redraws_with_the_draft_count_it_lands_under() {
        let store = Rc::new(GridStore::default());
        let rows = vec![RowData::draft(1), saved(1), saved(2)];
        store.replace(rows.clone());
        let heard = Rc::new(RefCell::new(Vec::new()));
        for row in store.rows() {
            let (store, heard) = (Rc::downgrade(&store), heard.clone());
            row.connect_revision_notify(move |_| {
                if let Some(store) = store.upgrade() {
                    heard.borrow_mut().push(store.draft_count());
                }
            });
        }

        store.replace(vec![saved(3), rows[1].clone(), rows[2].clone()]);

        assert_eq!(*heard.borrow(), [0, 0, 0], "a saved draft renumbers the rows below it");
    }

    #[test]
    fn drafts_go_on_top_newest_first_and_leave_in_runs() {
        let store = GridStore::default();
        store.replace(vec![saved(1)]);

        store.insert_drafts(&[10, 11, 12]);
        let order: Vec<_> = store.rows().map(|row| row.draft_id()).collect();
        assert_eq!(order, [Some(12), Some(11), Some(10), None]);

        let seen = changes(&store);
        store.remove_drafts(&[12, 11]);

        assert_eq!(*seen.borrow(), [(0, 2, 0)]);
        assert!(store.row_for(&RowKey::Draft(11)).is_none());
        assert!(store.row_for(&RowKey::Draft(10)).is_some());
    }

    #[test]
    fn append_adds_after_the_rows_held() {
        let store = GridStore::default();
        store.replace(vec![saved(1)]);

        store.append(vec![saved(2), saved(3)]);

        assert_eq!(store.len(), 3);
        assert_eq!(store.row_for(&key(3)).and_then(|row| store.position_of(&row)), Some(2));
    }
}
