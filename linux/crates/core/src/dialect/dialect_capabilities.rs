/// What an engine can promise about its own SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DialectCapabilities {
    /// Whether an affected-row count is the exact number of rows the
    /// statement changed. Where it is not, a write proves itself with
    /// a probe instead.
    pub exact_row_counts: bool,
}
