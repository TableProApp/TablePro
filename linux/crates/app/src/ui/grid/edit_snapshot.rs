use tablepro_core::edit::CellInput;

use super::RowObject;

/// An edit as it stood when it began. The commit goes to `row`, not to
/// whatever row the cell shows by then, and is measured against
/// `original`, the cell's value with any pending edit.
#[derive(Debug, Clone)]
pub struct EditSnapshot {
    pub row: RowObject,
    pub column: usize,
    pub original: CellInput,
}
