//! The pending-edit tracker moved to the shared core (ADR 0068,
//! superseding 0019). The app reaches it through `TabTrackerHandle`.
//! The worded save outcome and rejection stay in `crate::workspace`.

pub use tablepro_core::edits::{
    CellEdit, CellState, DeleteMark, DraftRow, KeyValue, RowKey, RowState, StatementSource, TabChangeTracker,
    TrackedChanges, pk_identity,
};
