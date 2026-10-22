use tablepro_core::browse::RowReference;

use crate::ui::clipboard::{CopyRequest, InClauseRows};
use crate::ui::export::ExportSource;
use crate::ui::grid::{RowJsonRequest, RowObject};

/// What the tab hands on and keeps no state for: copies in each format,
/// exports and the grid's notices.
#[derive(Debug)]
pub(crate) enum ClipboardInput {
    /// The paginator's Export button, or the grid's Export with the page
    /// as the grid holds it.
    Export(Option<ExportSource>),
    GridCopy(CopyRequest),
    GridCopyRowsAsInsert(Vec<RowObject>),
    GridCopyInClause(InClauseRows),
    CopySelectedRowsAsTsv,
    PasteNotSupported,
    GridShowRowJson(RowJsonRequest),
    GridShowToast(String),
    GridFollowReference(RowReference),
}
