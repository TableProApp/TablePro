/// What the tab knows of the page on screen. Its rows are the grid's:
/// the grid's store holds the only copy.
#[derive(Debug, Clone)]
pub(crate) struct PageState {
    pub row_count: usize,
    /// How many rows of the table come before the page.
    pub start_ordinal: u64,
    /// The page was read under a filter.
    pub filtered: bool,
    /// How long the server took to give the page, as the macOS bar
    /// reads it out. None for a page that was not read just now.
    pub elapsed: Option<std::time::Duration>,
}
