use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::RowDetailPane;
use crate::ui::data_grid::special_marks::mark_buffer;

impl RowDetailPane {
    pub(in crate::ui::data_grid) fn mark_special_characters(&self) {
        let marks = self.grid().is_some_and(|grid| grid.marks_special_characters());
        mark_buffer(self.imp().value_buffer.upcast_ref(), marks);
    }
}
