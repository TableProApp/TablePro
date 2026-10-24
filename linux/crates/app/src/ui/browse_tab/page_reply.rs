use tablepro_core::QueryResult;
use tablepro_core::browse::{PageLayout, PageRead, PagingMode};
use tablepro_core::meta::PagePosition;

use super::browse_pager::PageEdges;

/// A page as the server returned it, the row identity cells still after
/// the visible ones.
#[derive(Debug, Clone)]
pub(crate) struct PageReply {
    pub position: PagePosition,
    pub result: QueryResult,
    pub layout: PageLayout,
    pub edges: PageEdges,
    /// The table pages by key or heap address, so its last page reads
    /// back from its end.
    pub seeks: bool,
}

impl PageReply {
    /// `None` when the page starts at a key or at the table's end.
    pub fn offset(&self) -> Option<u64> {
        match self.position {
            PagePosition::First => Some(0),
            PagePosition::Offset(offset) => Some(offset),
            PagePosition::Last
            | PagePosition::AfterKey(_)
            | PagePosition::BeforeKey(_)
            | PagePosition::CtidWindow(_)
            | PagePosition::Resume(_) => None,
        }
    }
}

impl From<PageRead> for PageReply {
    fn from(read: PageRead) -> Self {
        Self {
            position: read.position,
            result: read.result,
            layout: read.layout,
            edges: PageEdges {
                last: read.mode == PagingMode::ServerPaging && read.next.is_none(),
                previous: read.previous,
                next: read.next,
            },
            seeks: matches!(read.mode, PagingMode::Keyset | PagingMode::CtidWindow),
        }
    }
}
