/// How many rows a table has, and how much that number is worth.
///
/// Counting exactly costs a full scan on most engines, so the
/// paginator asks for an estimate and the label says "about" when it
/// gets one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowCountEstimate {
    Exact(u64),
    Approximate(u64),
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TableEstimate {
    pub rows: RowCountEstimate,
    /// PostgreSQL heap blocks, which is what sizes a ctid window.
    pub heap_blocks: Option<u64>,
}

impl RowCountEstimate {
    pub fn value(self) -> Option<u64> {
        match self {
            Self::Exact(rows) | Self::Approximate(rows) => Some(rows),
            Self::Unknown => None,
        }
    }

    pub fn is_exact(self) -> bool {
        matches!(self, Self::Exact(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_approximate_count_has_a_value_but_is_not_exact() {
        assert_eq!(RowCountEstimate::Approximate(1_000).value(), Some(1_000));
        assert!(!RowCountEstimate::Approximate(1_000).is_exact());
        assert_eq!(RowCountEstimate::Unknown.value(), None);
        assert!(RowCountEstimate::Exact(7).is_exact());
    }
}
