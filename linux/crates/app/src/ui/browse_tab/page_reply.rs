use tablepro_core::QueryResult;
use tablepro_core::browse::{PageLayout, PageRead, PagingMode};
use tablepro_core::meta::PagePosition;

use super::browse_pager::PageEdges;

#[derive(Debug, Clone)]
pub(crate) struct PageReply {
    pub position: PagePosition,
    pub result: QueryResult,
    pub layout: PageLayout,
    pub edges: PageEdges,
    pub seeks: bool,
    pub elapsed: std::time::Duration,
}

impl PageReply {
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

    pub fn new(read: PageRead, elapsed: std::time::Duration) -> Self {
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
            elapsed,
        }
    }
}
