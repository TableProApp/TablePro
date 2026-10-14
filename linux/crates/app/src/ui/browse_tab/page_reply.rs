use tablepro_core::QueryResult;
use tablepro_core::browse::PageLayout;
use tablepro_core::meta::PagePosition;

/// A page as the server returned it, the row identity cells still after
/// the visible ones.
#[derive(Debug, Clone)]
pub(crate) struct PageReply {
    pub position: PagePosition,
    pub result: QueryResult,
    pub layout: PageLayout,
}

impl PageReply {
    /// `None` when the page starts at a key or a ctid window.
    pub fn offset(&self) -> Option<u64> {
        match self.position {
            PagePosition::First => Some(0),
            PagePosition::Offset(offset) => Some(offset),
            PagePosition::AfterKey(_) | PagePosition::BeforeKey(_) | PagePosition::CtidWindow { .. } => None,
        }
    }
}
