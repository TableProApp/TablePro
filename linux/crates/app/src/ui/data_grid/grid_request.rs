use tablepro_core::FilterRule;
use tablepro_core::browse::RowReference;

use crate::services::share_subject::SharedRows;
use crate::ui::export::ExportSource;

/// What a grid asks of its host: only what the grid cannot do itself.
#[derive(Debug, Clone)]
pub enum GridRequest {
    /// Read the rows again in this order, `None` in the server's own.
    Sort(Option<(usize, bool)>),
    Export(ExportSource),
    Share(SharedRows),
    FollowReference(RowReference),
    FilterByValue(FilterRule),
    Toast(String),
    /// The tracker's pending changes changed: count, undo or redo.
    PendingChanged,
    // The user confirmed showing the tab's masked values.
    RevealMasked,
}
