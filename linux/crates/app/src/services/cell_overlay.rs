use tablepro_core::Value;

use super::change_tracker::CellState;

/// One cell as the grid draws it, copied out of the tracker so a bind
/// holds no borrow while it updates widgets.
#[derive(Debug, Clone, PartialEq)]
pub struct CellOverlay {
    /// The pending edit when there is one, else the fetched value.
    pub value: Value,
    pub state: CellState,
    /// The row produced the statement a save just failed on.
    pub error_flash: bool,
}
