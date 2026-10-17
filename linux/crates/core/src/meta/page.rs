use crate::value::Value;

/// Where in the table a page starts.
#[derive(Debug, Clone, PartialEq)]
pub enum PagePosition {
    First,
    /// The table's last rows, read backward from its end. The SQL
    /// reverses the order and the reader puts the rows back.
    Last,
    Offset(u64),
    /// Forward from the last row of the page before, by its key.
    AfterKey(Vec<Value>),
    /// Backward from the first row of the page after, by its key. The
    /// SQL reverses the order and the reader puts the rows back.
    BeforeKey(Vec<Value>),
    /// One range of PostgreSQL heap addresses, for a table with no key.
    /// A page is read through as many of these as it takes to fill it.
    CtidWindow(CtidWindow),
}

/// A PostgreSQL heap address: block, then line pointer. Line pointers
/// start at 1, so `(block, 0)` sorts before every row in that block.
pub type HeapAddress = (u32, u16);

/// The rows between two heap addresses. A bound left out runs to that
/// end of the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CtidWindow {
    pub after: Option<HeapAddress>,
    pub before: Option<HeapAddress>,
    /// Read from `before` down, for a page that ends there.
    pub backward: bool,
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
