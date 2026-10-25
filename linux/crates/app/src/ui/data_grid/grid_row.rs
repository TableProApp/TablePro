use std::cell::{Cell, RefCell};
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::Value;

use crate::services::change_tracker::RowKey;
use crate::services::grid::GridRowId;

/// What one row of a grid shows: a saved row's key and cells as read, a
/// result row's cells, or a draft, whose cells live in the tracker.
#[derive(Debug, Clone, PartialEq)]
pub struct RowData {
    pub id: GridRowId,
    pub cells: Option<Arc<[Value]>>,
}

impl RowData {
    pub fn persisted(key: Option<RowKey>, cells: Arc<[Value]>) -> Self {
        let id = match key {
            Some(key) => GridRowId::Persisted(key),
            None => GridRowId::Unkeyed,
        };
        Self { id, cells: Some(cells) }
    }

    pub fn result(cells: Arc<[Value]>) -> Self {
        Self {
            id: GridRowId::Result,
            cells: Some(cells),
        }
    }

    pub fn draft(draft_id: u64) -> Self {
        Self {
            id: GridRowId::Draft(draft_id),
            cells: None,
        }
    }

    fn same_as(&self, other: &RowData) -> bool {
        let same_cells = match (&self.cells, &other.cells) {
            (Some(left), Some(right)) => Arc::ptr_eq(left, right),
            (None, None) => true,
            _ => false,
        };
        same_cells && self.id == other.id
    }
}

mod imp {
    use super::*;

    #[derive(glib::Properties)]
    #[properties(wrapper_type = super::GridRow)]
    pub struct GridRow {
        pub data: RefCell<RowData>,
        /// Moves whenever the row draws differently: its data or its
        /// pending state changed.
        #[property(get)]
        pub revision: Cell<u32>,
        /// Moves only when the slot is given another row, so anything that
        /// captured the row (a menu, an editor) can tell it is gone.
        pub generation: Cell<u64>,
    }

    impl Default for GridRow {
        fn default() -> Self {
            Self {
                data: RefCell::new(RowData::result(Arc::from([]))),
                revision: Cell::new(0),
                generation: Cell::new(0),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridRow {
        const NAME: &'static str = "TableProGridRow";
        type Type = super::GridRow;
    }

    #[glib::derived_properties]
    impl ObjectImpl for GridRow {}
}

glib::wrapper! {
    /// A slot of the grid's store. A reload writes the new rows into the
    /// slots it already has, so GTK keeps every row and cell widget and
    /// only the cells draw again.
    pub struct GridRow(ObjectSubclass<imp::GridRow>);
}

impl GridRow {
    pub fn new(data: RowData) -> Self {
        let row: Self = glib::Object::new();
        row.imp().data.replace(data);
        row
    }

    pub fn id(&self) -> GridRowId {
        self.imp().data.borrow().id.clone()
    }

    pub fn key(&self) -> Option<RowKey> {
        self.imp().data.borrow().id.key().cloned()
    }

    pub fn tracker_key(&self) -> Option<RowKey> {
        self.imp().data.borrow().id.tracker_key()
    }

    pub fn draft_id(&self) -> Option<u64> {
        self.imp().data.borrow().id.draft_id()
    }

    pub fn cells(&self) -> Option<Arc<[Value]>> {
        self.imp().data.borrow().cells.clone()
    }

    pub fn data(&self) -> RowData {
        self.imp().data.borrow().clone()
    }

    pub fn generation(&self) -> u64 {
        self.imp().generation.get()
    }

    /// Give the slot another row, and say whether it took one. The same
    /// row again changes nothing, so a draft that stays on top keeps its
    /// open edit.
    pub fn set_data(&self, data: RowData) -> bool {
        if self.imp().data.borrow().same_as(&data) {
            return false;
        }
        self.imp().data.replace(data);
        let generation = &self.imp().generation;
        generation.set(generation.get().wrapping_add(1));
        self.bump_revision();
        true
    }

    /// The row left the store: whatever holds it pinned acts on nothing.
    pub fn retire(&self) {
        let generation = &self.imp().generation;
        generation.set(generation.get().wrapping_add(1));
    }

    pub fn bump_revision(&self) {
        let revision = &self.imp().revision;
        revision.set(revision.get().wrapping_add(1));
        self.notify_revision();
    }

    /// A hold on the row as it is now, which stops resolving once the
    /// slot is given another row.
    pub fn pin(&self) -> PinnedRow {
        PinnedRow {
            row: self.clone(),
            generation: self.generation(),
        }
    }
}

/// A row captured by a menu, an editor or a copy. It resolves only while
/// its slot still holds the row it captured.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinnedRow {
    row: GridRow,
    generation: u64,
}

impl PinnedRow {
    pub fn get(&self) -> Option<&GridRow> {
        (self.row.generation() == self.generation).then_some(&self.row)
    }

    pub fn is_current(&self) -> bool {
        self.get().is_some()
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    #[test]
    fn a_new_row_moves_the_generation_and_the_revision() {
        let row = GridRow::new(RowData::persisted(Some(key(1)), Arc::from([Value::Int(1)])));
        let heard = Rc::new(Cell::new(0));
        let counter = heard.clone();
        row.connect_revision_notify(move |_| counter.set(counter.get() + 1));
        let pinned = row.pin();

        row.set_data(RowData::persisted(Some(key(2)), Arc::from([Value::Int(2)])));

        assert_eq!(row.key(), Some(key(2)));
        assert_eq!(heard.get(), 1);
        assert!(!pinned.is_current(), "a pin on the row it replaced resolves to nothing");
    }

    #[test]
    fn the_same_row_again_keeps_the_generation() {
        let cells: Arc<[Value]> = Arc::from([Value::Int(1)]);
        let row = GridRow::new(RowData::persisted(Some(key(1)), cells.clone()));
        let pinned = row.pin();

        row.set_data(RowData::persisted(Some(key(1)), cells));
        row.set_data(RowData::draft(4));
        let draft = row.pin();
        row.set_data(RowData::draft(4));

        assert!(!pinned.is_current());
        assert!(draft.is_current(), "a draft that stays keeps its pins");
    }

    #[test]
    fn a_pending_change_redraws_without_releasing_pins() {
        let row = GridRow::new(RowData::draft(1));
        let pinned = row.pin();

        row.bump_revision();

        assert_eq!(row.revision(), 1);
        assert!(pinned.is_current());
    }
}
