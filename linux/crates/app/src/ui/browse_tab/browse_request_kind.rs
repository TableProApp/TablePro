/// The reads a browse tab makes. Each kind has at most one request
/// running; a new one replaces the last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum BrowseRequestKind {
    /// The table's columns and how its rows are identified. A page and
    /// a count are built from them, so both wait for this one.
    Columns,
    Page,
    Count,
}
