use tablepro_core::QueryResult;
use tablepro_core::meta::PagePosition;

/// One page of rows and where in the table it starts.
#[derive(Debug, Clone)]
pub(crate) struct PageReply {
    pub position: PagePosition,
    pub result: QueryResult,
}

impl PageReply {
    /// The row offset the page starts at, for the paginator.
    pub fn offset(&self) -> Option<u64> {
        match self.position {
            PagePosition::First => Some(0),
            PagePosition::Offset(offset) => Some(offset),
            PagePosition::AfterKey(_) | PagePosition::BeforeKey(_) | PagePosition::CtidWindow { .. } => None,
        }
    }
}
