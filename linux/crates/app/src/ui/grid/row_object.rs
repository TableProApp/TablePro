use std::cell::OnceCell;
use std::sync::Arc;

use gtk4::glib;
use gtk4::subclass::prelude::*;

use tablepro_core::Value;

use super::GridRowId;
use crate::services::change_tracker::RowKey;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct RowObject {
        pub id: OnceCell<GridRowId>,
        /// The row as it was read. A draft has none: its cells are the
        /// tracker's.
        pub cells: OnceCell<Arc<[Value]>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for RowObject {
        const NAME: &'static str = "TableProRowObject";
        type Type = super::RowObject;
    }

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

    /// A new object for the same row. The list item manager skips the
    /// rebind for an items-changed that keeps the same item, so a row
    /// whose pending state changed is swapped for one of these.
    pub fn replacement(&self) -> Self {
        Self::with(self.id().clone(), self.imp().cells.get().cloned())
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
}

#[cfg(test)]
mod tests {
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
        assert_eq!(persisted.replacement().id(), persisted.id());
        assert_eq!(persisted.replacement().cells(), persisted.cells());
    }
}
