//! A browse tab's or a result's pending row edits, keyed by primary
//! key, with undo and the save batch. One engine for every platform
//! (ADR 0068, superseding 0019): Linux uses it directly, Windows and
//! macOS reach it through the FFI. The grid copy and display modules
//! stay in each app.

mod cell_overlay;
mod column_relayout;
mod outcome;
mod save_batch;
mod touch;
mod tracker;
mod tracker_delta;
mod tracker_edit;
mod undo_op;

pub use cell_overlay::{CellMarks, CellOverlay};
pub use outcome::{PendingState, SaveOutcome, SaveSnapshot, TrackerRejection, UnknownCause};
pub use save_batch::{SaveBatch, SaveTarget};
pub use touch::Touch;
pub use tracker::{
    CellEdit, CellState, DeleteMark, DraftRow, KeyValue, RowKey, RowState, StatementSource, TabChangeTracker,
    TrackedChanges, pk_identity,
};
pub use tracker_delta::TrackerDelta;
pub use tracker_edit::TrackerEdit;
pub use undo_op::{DeleteStep, UndoOp};
