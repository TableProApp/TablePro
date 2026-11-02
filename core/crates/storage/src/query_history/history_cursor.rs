use crate::unix_time::to_unix;

use super::Entry;

/// Where the next page starts: just after the last entry shown, in the
/// order pinned first, then newest, then highest id. The id breaks the
/// tie between runs stamped in the same second.
///
/// Cursors compare as the page query compares rows, so an entry whose
/// cursor is below a page's `next` belongs to a later page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct HistoryCursor {
    pub(super) pinned: bool,
    pub(super) executed_at: i64,
    pub(super) id: i64,
}

impl HistoryCursor {
    pub fn after(entry: &Entry) -> Self {
        Self {
            pinned: entry.pinned,
            executed_at: to_unix(entry.executed_at),
            id: entry.id,
        }
    }
}
