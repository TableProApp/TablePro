use std::cell::{Cell, RefCell};

use gtk4::glib;
use gtk4::subclass::prelude::*;

use tablepro_core::Value;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct RowObject {
        pub cells: RefCell<Vec<Value>>,
        /// Tells a draft apart from a persisted row whose key columns
        /// happen to be NULL.
        pub draft_id: Cell<Option<u64>>,
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

impl RowObject {
    pub fn new(cells: Vec<Value>) -> Self {
        let obj: Self = glib::Object::new();
        *obj.imp().cells.borrow_mut() = cells;
        obj
    }

    pub fn new_draft(draft_id: u64, cells: Vec<Value>) -> Self {
        let obj = Self::new(cells);
        obj.imp().draft_id.set(Some(draft_id));
        obj
    }

    pub fn draft_id(&self) -> Option<u64> {
        self.imp().draft_id.get()
    }

    pub fn cell_value(&self, idx: usize) -> Value {
        self.imp().cells.borrow().get(idx).cloned().unwrap_or(Value::Null)
    }

    pub fn cells_clone(&self) -> Vec<Value> {
        self.imp().cells.borrow().clone()
    }

    /// Spares a hot path the copy `cells_clone` makes.
    pub fn with_cells<R>(&self, f: impl FnOnce(&[Value]) -> R) -> R {
        f(&self.imp().cells.borrow())
    }

    pub fn set_cell(&self, idx: usize, value: Value) {
        let mut cells = self.imp().cells.borrow_mut();
        if idx < cells.len() {
            cells[idx] = value;
        }
    }
}
