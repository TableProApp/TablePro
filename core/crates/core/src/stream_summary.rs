/// How a streamed read ended, once every row went to the sink.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct StreamSummary {
    pub rows: u64,
}

impl StreamSummary {
    pub fn new(rows: u64) -> Self {
        Self { rows }
    }
}
