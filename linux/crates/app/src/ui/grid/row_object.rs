use std::cell::{Cell, OnceCell};
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use tablepro_core::Value;

use super::GridRowId;
use crate::services::change_tracker::RowKey;

mod imp {
    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::RowObject)]
    pub struct RowObject {
        pub id: OnceCell<GridRowId>,
        /// The row as it was read. A draft has none: its cells are the
        /// tracker's.
        pub cells: OnceCell<Arc<[Value]>>,
        /// Moves on when the row's pending state changes, so the cells
        /// bound to it draw again without the store swapping the row.
        #[property(get)]
        pub revision: Cell<u32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for RowObject {
        const NAME: &'static str = "TableProRowObject";
        type Type = super::RowObject;
    }

    #[glib::derived_properties]
    impl ObjectImpl for RowObject {}
}

glib::wrapper! {
    pub struct RowObject(ObjectSubclass<imp::RowObject>);
}

/// What a row made by `glib::Object::new` rather than a constructor
/// here reads as: nothing to edit.
static UNNAMED: GridRowId = GridRowId::Result;

impl RowObject {
    fn with(id: GridRowId, cells: Option<Arc<[Value]>>) -> Self {
        let row: Self = glib::Object::new();
        let _ = row.imp().id.set(id);
        if let Some(cells) = cells {
            let _ = row.imp().cells.set(cells);
        }
        row
    }

    /// A row read from a table. `None` for a row with no usable key.
    pub fn persisted(key: Option<RowKey>, cells: Arc<[Value]>) -> Self {
        let id = match key {
            Some(key) => GridRowId::Persisted(key),
            None => GridRowId::Unkeyed,
        };
        Self::with(id, Some(cells))
    }

    pub fn draft(draft_id: u64) -> Self {
        Self::with(GridRowId::Draft(draft_id), None)
    }

    pub fn result(cells: Arc<[Value]>) -> Self {
        Self::with(GridRowId::Result, Some(cells))
    }

    pub fn id(&self) -> &GridRowId {
        self.imp().id.get().unwrap_or(&UNNAMED)
    }

    pub fn key(&self) -> Option<&RowKey> {
        self.id().key()
    }

    pub fn draft_id(&self) -> Option<u64> {
        self.id().draft_id()
    }

    pub fn cells(&self) -> Option<Arc<[Value]>> {
        self.imp().cells.get().cloned()
    }

    pub fn cell(&self, column: usize) -> Option<&Value> {
        self.imp().cells.get()?.get(column)
    }

    /// Tell the cells bound to this row that its pending state changed.
    pub(crate) fn bump_revision(&self) {
        let revision = &self.imp().revision;
        revision.set(revision.get().wrapping_add(1));
        self.notify_revision();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use tablepro_core::Value;

    use super::RowObject;
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::GridRowId;

    #[test]
    fn a_row_keeps_the_identity_it_was_made_with() {
        let key = RowKey::from_pk_values(&[Value::Int(2)]).expect("a key");
        let persisted = RowObject::persisted(Some(key.clone()), vec![Value::Int(2)].into());
        let unkeyed = RowObject::persisted(None, vec![Value::Int(2)].into());
        let draft = RowObject::draft(5);

        assert_eq!(persisted.key(), Some(&key));
        assert_eq!(persisted.cell(0), Some(&Value::Int(2)));
        assert_eq!(unkeyed.id(), &GridRowId::Unkeyed);
        assert_eq!(draft.draft_id(), Some(5));
        assert!(draft.cells().is_none(), "a draft's cells are the tracker's");
    }

    #[test]
    fn bump_revision_notifies_each_listener_once() {
        let row = RowObject::draft(1);
        let heard = Rc::new(Cell::new(0));
        let counter = heard.clone();
        row.connect_revision_notify(move |_| counter.set(counter.get() + 1));

        row.bump_revision();
        row.bump_revision();

        assert_eq!(row.revision(), 2);
        assert_eq!(heard.get(), 2);
    }
}
