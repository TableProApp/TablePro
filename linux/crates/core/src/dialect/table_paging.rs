/// How a page of a table is read on an engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TablePaging {
    /// The statement carries the window: an ORDER BY with an offset, a
    /// key to seek past or a block range.
    InStatement,
    /// The server pages a read itself and hands back where it stopped,
    /// as CQL's paging state does. A table is read in the engine's own
    /// order, which no ORDER BY can change.
    ServerState,
}
