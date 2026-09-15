use crate::value::Value;

/// Where in the table a page starts.
#[derive(Debug, Clone, PartialEq)]
pub enum PagePosition {
    First,
    Offset(u64),
    /// Keyset paging forward from the last row of the page before.
    AfterKey(Vec<Value>),
    /// Keyset paging backward. The SQL reverses the order and the
    /// fetcher reverses the rows back.
    BeforeKey(Vec<Value>),
    /// A block of the PostgreSQL heap, for a table with no key.
    CtidWindow {
        after: Option<(u32, u16)>,
        end_block: u64,
    },
}

/// Whether the same page read twice shows the same rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageStability {
    /// A total order over a unique key: paging cannot skip or repeat.
    Stable,
    /// The order has ties, so rows can move between pages.
    NonUniqueOrder,
    /// No order at all. The engine may return rows in any order each
    /// time.
    Unordered,
}

/// What the page costs the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageCost {
    /// An index seek. Constant whatever the offset.
    KeySeek,
    /// A scan of one physical block range.
    BlockWindow,
    /// A sort of the whole table per page, which is what OFFSET costs
    /// at a large offset.
    SortPerPage,
}

impl PageStability {
    /// Whether the grid should warn that paging may skip or repeat a
    /// row.
    pub fn needs_warning(self) -> bool {
        !matches!(self, Self::Stable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anything_but_a_total_order_is_worth_warning_about() {
        assert!(!PageStability::Stable.needs_warning());
        assert!(PageStability::NonUniqueOrder.needs_warning());
        assert!(PageStability::Unordered.needs_warning());
    }
}
