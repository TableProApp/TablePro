use tablepro_core::FilterRule;
use tablepro_core::browse::RowReference;

use crate::ui::export::ExportSource;

/// What a grid asks of its host: only what the grid cannot do itself.
#[derive(Debug, Clone)]
pub enum GridRequest {
    /// Read the rows again in this order, `None` in the server's own.
    Sort(Option<(usize, bool)>),
    Export(ExportSource),
    FollowReference(RowReference),
    FilterByValue(FilterRule),
    Toast(String),
    /// The tracker's pending changes changed: count, undo or redo.
    PendingChanged,
}
