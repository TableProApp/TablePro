use libadwaita as adw;
use tablepro_core::ColumnInfo;

use super::row_deletion::RowDeletion;

/// A bulk delete the user has not answered yet.
///
/// Its rows are keyed by the primary key of the columns they were read
/// under, so a change to those columns moves them or cancels the delete
/// before it lands.
pub(super) struct ConfirmingDelete {
    pub(super) ticket: u64,
    pub(super) deletion: RowDeletion,
    pub(super) columns: Vec<ColumnInfo>,
    pub(super) dialog: adw::AlertDialog,
}
