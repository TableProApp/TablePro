use uuid::Uuid;

use super::TabRecord;

/// One page of the tab view, in its order: the tab it shows and what of
/// it is saved. A tab with nothing to reopen has no record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabSnapshot {
    pub id: Uuid,
    pub record: Option<TabRecord>,
}
