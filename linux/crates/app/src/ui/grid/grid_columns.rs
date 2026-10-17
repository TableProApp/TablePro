use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};

use super::RowObject;
use super::cell_editor_kind::CellEditorKind;
use super::column_drawing::ColumnDrawing;

/// The grid's columns, for finding a cell's neighbours. The user can
/// drag the columns into another order, so the order is read from the
/// view each time.
#[derive(Default)]
pub(super) struct GridColumns {
    columns: RefCell<Vec<GridColumn>>,
}

struct GridColumn {
    index: usize,
    /// The view owns its columns, and their cells hold this.
    view_column: glib::WeakRef<gtk::ColumnViewColumn>,
    drawing: Rc<ColumnDrawing>,
}

#[derive(Clone)]
pub(super) struct ShownColumn {
    pub(super) view_column: gtk::ColumnViewColumn,
    /// The column's place in the result, which is what its cells hold.
    pub(super) index: usize,
    drawing: Rc<ColumnDrawing>,
}

impl ShownColumn {
    /// Whether the column's cell in `row` opens an editor. A check box
    /// is edited where it stands, so it opens none.
    pub(super) fn opens_editor(&self, row: &RowObject) -> bool {
        let Some(column) = self.drawing.catalog.as_ref() else {
            return false;
        };
        let editability = self.drawing.lock(row.id()).map_or(Ok(()), Err);
        matches!(
            CellEditorKind::for_cell(column, editability),
            CellEditorKind::Inline { .. } | CellEditorKind::Multiline { .. } | CellEditorKind::Calendar
        )
    }
}

impl GridColumns {
    pub(super) fn push(&self, index: usize, view_column: &gtk::ColumnViewColumn, drawing: Rc<ColumnDrawing>) {
        self.columns.borrow_mut().push(GridColumn {
            index,
            view_column: view_column.downgrade(),
            drawing,
        });
    }

    /// Measure the rows a change to `store` brought in. A change that
    /// replaced every row, a new page, measures from scratch; adding or
    /// removing a draft, which has no cells, measures nothing.
    pub(super) fn measure_change(&self, store: &gio::ListStore, position: u32, added: u32) {
        let replaced_all = position == 0 && store.n_items() == added;
        if !replaced_all && added == 0 {
            return;
        }
        let rows: Vec<RowObject> = (position..position.saturating_add(added))
            .filter_map(|position| store.item(position).and_downcast())
            .collect();
        for column in self.columns.borrow().iter() {
            let drawing = &column.drawing;
            match replaced_all {
                true => drawing.figures.measure(&drawing.column_type, column.index, &rows),
                false => drawing.figures.extend(&drawing.column_type, column.index, &rows),
            }
        }
    }

    pub(super) fn shown(&self, view: &gtk::ColumnView) -> Vec<ShownColumn> {
        let columns = self.columns.borrow();
        let model = view.columns();
        (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<gtk::ColumnViewColumn>())
            .filter(gtk::ColumnViewColumn::is_visible)
            .filter_map(|view_column| {
                let column = columns
                    .iter()
                    .find(|column| column.view_column.upgrade().as_ref() == Some(&view_column))?;
                Some(ShownColumn {
                    view_column,
                    index: column.index,
                    drawing: column.drawing.clone(),
                })
            })
            .collect()
    }
}
