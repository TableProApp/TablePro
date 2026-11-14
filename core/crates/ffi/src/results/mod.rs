// The design: core/docs/decisions/0003-result-windows-for-native-grids.md.

mod cell_text;
mod column_cells;
mod cursor;
mod result_set;
mod store;
mod value_kind;

pub(crate) use cursor::Cursor;
pub use result_set::{CellBytes, CellTextHead, ResultColumnInfo, ResultSet};
pub(crate) use store::ResultStore;
pub use value_kind::ValueKind;
