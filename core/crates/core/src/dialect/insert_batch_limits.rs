/// How much one multi-row INSERT may carry on an engine. A batch of rows
/// is cut into statements that each stay within all three.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InsertBatchLimits {
    /// Rows in one VALUES list.
    pub rows: usize,
    /// Parameters bound to one statement.
    pub params: usize,
    /// The values one statement carries, measured as their text, so a
    /// statement stays well inside the engine's packet or request size.
    pub value_bytes: usize,
}

impl InsertBatchLimits {
    /// Within what PostgreSQL (65,535 parameters), MySQL (65,535
    /// placeholders, a 4 MiB packet on older servers) and SQLite (32,766
    /// variables) accept. A thousand rows already make one round trip
    /// a small share of the time a statement takes.
    pub const DEFAULT: Self = Self {
        rows: 1_000,
        params: 30_000,
        value_bytes: 1 << 20,
    };
}
