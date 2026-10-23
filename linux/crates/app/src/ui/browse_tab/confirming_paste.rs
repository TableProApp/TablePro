use libadwaita as adw;
use tablepro_core::ColumnInfo;
use tablepro_core::import::PastedRows;

/// A paste large enough to ask about, waiting for the answer. Its cells
/// sit in the order of the columns they were read against.
pub(super) struct ConfirmingPaste {
    pub(super) ticket: u64,
    pub(super) rows: PastedRows,
    pub(super) columns: Vec<ColumnInfo>,
    pub(super) dialog: adw::AlertDialog,
}
