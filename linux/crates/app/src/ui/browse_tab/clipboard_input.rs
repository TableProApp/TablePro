use tablepro_core::browse::RowReference;

use super::paste_at::PasteAt;
use super::paste_read::PasteRead;
use crate::ui::clipboard::{CopyRequest, InClauseRows};
use crate::ui::export::ExportSource;
use crate::ui::grid::{RowJsonRequest, RowObject};

/// Copies in each format, pastes, exports and the grid's notices.
#[derive(Debug)]
pub(crate) enum ClipboardInput {
    /// The paginator's Export button, or the grid's Export with the page
    /// as the grid holds it.
    Export(Option<ExportSource>),
    GridCopy(CopyRequest),
    GridCopyRowsAsInsert(Vec<RowObject>),
    GridCopyInClause(InClauseRows),
    CopySelectedRowsAsTsv,
    /// Ctrl+V or a menu's Paste, at the cell it names.
    Paste(Option<PasteAt>),
    PasteRead(Box<PasteRead>),
    /// The user answered the question a large paste asked.
    PasteAnswered {
        ticket: u64,
        confirmed: bool,
    },
    GridShowRowJson(RowJsonRequest),
    GridShowToast(String),
    GridFollowReference(RowReference),
}
