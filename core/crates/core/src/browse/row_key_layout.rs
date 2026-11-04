use crate::meta::EngineRowIdPart;

/// Where a page's row key lives in the columns it selected.
///
/// A key made of real columns is read from the visible ones. An engine
/// row id is projected after them, so the grid never sees it.
#[derive(Debug, Clone, PartialEq)]
pub enum RowKeyLayout {
    /// Positions in the visible columns, in key order.
    Columns(Vec<usize>),
    EngineRowId {
        /// Where the hidden columns start, which is the visible count.
        first_hidden: usize,
        parts: &'static [EngineRowIdPart],
    },
    /// Nothing names a row, so the grid is read-only.
    ReadOnly,
}

impl RowKeyLayout {
    /// How many columns the query selected beyond the visible ones.
    pub fn hidden_count(&self) -> usize {
        match self {
            Self::EngineRowId { parts, .. } => parts.len(),
            Self::Columns(_) | Self::ReadOnly => 0,
        }
    }

    pub fn is_read_only(&self) -> bool {
        matches!(self, Self::ReadOnly)
    }
}
