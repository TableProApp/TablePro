pub use tablepro_core::edits::{CellMarks, CellOverlay};

#[cfg(test)]
pub(crate) trait CellOverlayExt {
    /// The value the cell shows over `fetched`, a cell left to the
    /// server reading as NULL.
    fn shown(self, fetched: tablepro_core::Value) -> tablepro_core::Value;
}

#[cfg(test)]
impl CellOverlayExt for CellOverlay {
    fn shown(self, fetched: tablepro_core::Value) -> tablepro_core::Value {
        use tablepro_core::edit::CellInput;
        match self.pending {
            Some(CellInput::Value(value)) => value,
            Some(CellInput::Default | CellInput::Expression(_)) => tablepro_core::Value::Null,
            None => fetched,
        }
    }
}
