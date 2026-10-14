#[cfg(test)]
use tablepro_core::Value;
use tablepro_core::edit::CellInput;

use super::change_tracker::CellState;

/// One cell's pending state, copied out of the tracker so a draw holds
/// no borrow while it updates widgets. Only a pending value is copied: a
/// clean cell is drawn from the row itself.
#[derive(Debug, Clone, PartialEq)]
pub struct CellOverlay {
    /// The cell's pending input, `None` when it shows what was read. A
    /// draft's cell is always the tracker's.
    pub pending: Option<CellInput>,
    pub state: CellState,
    /// The row produced the statement a save just failed on.
    pub error_flash: bool,
}

#[cfg(test)]
impl CellOverlay {
    /// The value the cell shows over `fetched`, a cell left to the
    /// server reading as NULL.
    pub fn shown(self, fetched: Value) -> Value {
        match self.pending {
            Some(CellInput::Value(value)) => value,
            Some(CellInput::Default) => Value::Null,
            None => fetched,
        }
    }
}
