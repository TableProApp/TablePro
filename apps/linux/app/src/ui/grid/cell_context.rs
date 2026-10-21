use std::cell::RefCell;
use std::rc::Rc;

use gtk4::{glib, prelude::*};

pub(super) struct CellContext {
    pub(super) widget: gtk4::Widget,
    pub(super) col_index: usize,
    pub(super) column_name: String,
}

struct WeakCellContext {
    widget: glib::WeakRef<gtk4::Widget>,
    col_index: usize,
    column_name: String,
}

#[derive(Clone, Default)]
pub(super) struct CellContextStore(Rc<RefCell<Option<WeakCellContext>>>);

impl CellContextStore {
    pub(super) fn set(&self, widget: &gtk4::Widget, col_index: usize, column_name: String) {
        self.0.replace(Some(WeakCellContext {
            widget: widget.downgrade(),
            col_index,
            column_name,
        }));
    }

    pub(super) fn snapshot(&self) -> Option<CellContext> {
        let state = self.0.borrow();
        let state = state.as_ref()?;
        Some(CellContext {
            widget: state.widget.upgrade()?,
            col_index: state.col_index,
            column_name: state.column_name.clone(),
        })
    }
}
