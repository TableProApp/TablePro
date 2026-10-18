use super::{Entry, HistoryCursor};

/// The most entries one page returns, whatever the caller asks for.
pub const MAX_PAGE_SIZE: usize = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryPageRequest {
    /// `None` for the first page.
    pub after: Option<HistoryCursor>,
    /// Clamped to 1 through `MAX_PAGE_SIZE`.
    pub limit: usize,
}

impl HistoryPageRequest {
    pub fn first(limit: usize) -> Self {
        Self { after: None, limit }
    }
}

#[derive(Debug, Clone, Default)]
pub struct HistoryPage {
    pub entries: Vec<Entry>,
    /// Where the next page starts, or `None` when this was the last.
    pub next: Option<HistoryCursor>,
}
