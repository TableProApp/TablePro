#[derive(Debug, Clone)]
pub(crate) struct PageState {
    pub row_count: usize,
    pub start_ordinal: u64,
    pub filtered: bool,
    pub elapsed: std::time::Duration,
}
