// The design: core/docs/decisions/0003-result-windows-for-native-grids.md.

mod cell_text;
mod column_cells;
mod cursor;
mod grid_copy;
mod result_set;
mod store;
mod value_kind;

pub(crate) use cursor::Cursor;
pub use grid_copy::{GridCopy, GridCopyFormat};
pub(crate) use grid_copy::{copy_as_insert, copy_as_values, copy_in_clause};
pub use result_set::{CellBytes, CellTextHead, ResultColumnInfo, ResultSet};
pub(crate) use store::ResultStore;
pub use value_kind::ValueKind;
