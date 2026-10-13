use tablepro_core::QueryResult;
use tablepro_core::meta::PagePosition;

#[derive(Debug, Clone)]
pub(crate) struct PageReply {
    pub position: PagePosition,
    pub result: QueryResult,
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
