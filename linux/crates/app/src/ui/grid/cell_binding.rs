use gtk4::glib;
use gtk4::prelude::*;

use super::{GridCell, RowObject};

/// A cell's hold on the row it shows. Dropping it disconnects the cell
/// from the row's revision, so a recycled cell never draws for a row it
/// left.
#[derive(Debug)]
pub struct CellBinding {
    row: RowObject,
    handler: Option<glib::SignalHandlerId>,
}

impl CellBinding {
    pub fn new(cell: &GridCell, row: &RowObject) -> Self {
        let handler = row.connect_revision_notify(glib::clone!(
            #[weak]
            cell,
            move |_| cell.render()
        ));
        Self {
            row: row.clone(),
            handler: Some(handler),
        }
    }

    pub fn row(&self) -> &RowObject {
        &self.row
    }
}

impl Drop for CellBinding {
    fn drop(&mut self) {
        if let Some(handler) = self.handler.take() {
            self.row.disconnect(handler);
        }
    }
}
