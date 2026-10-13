use tablepro_core::WriteKind;
use uuid::Uuid;

use super::SaveOutcome;
use crate::services::change_tracker::StatementSource;

/// A save that ended, after its tracker and the ledger took the outcome
/// in, for the tab to show.
#[derive(Debug, Clone)]
pub struct SaveSettled {
    pub tab: Uuid,
    pub kind: WriteKind,
    pub outcome: SaveOutcome,
    /// The grid row behind the statement a row save stopped at.
    pub failing: Option<StatementSource>,
    /// The name a structure save leaves the table with, when it created
    /// or renamed one.
    pub saved_table_name: Option<String>,
}
