/// What an engine can promise about its own SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DialectCapabilities {
    /// Whether an affected-row count is the exact number of rows the
    /// statement changed. Where it is not, a write proves itself with
    /// a probe instead.
    pub exact_row_counts: bool,
    pub insert_conflict: InsertConflict,
}

/// What the dialect's INSERT does with a key that is already taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsertConflict {
    /// The server refuses it with an error.
    Refused,
    /// It writes nothing and reports no row, as CQL's IF NOT EXISTS
    /// does. A save proves each insert wrote its row by the affected
    /// count.
    Skipped,
    /// It replaces the row that has the key, as a plain CQL INSERT
    /// does. A save first proves no row has the key.
    Replaced,
}
