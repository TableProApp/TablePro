use async_trait::async_trait;

use crate::result_event::ResultEvent;

/// Whether the run should keep going.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SinkFlow {
    Continue,
    /// Nobody is reading any more, so the run is stopped rather than
    /// left to finish into nothing.
    ConsumerGone,
}

/// Where a run's events go.
///
/// Each event is awaited before the next is read off the wire, so a
/// grid that cannot keep up slows the read instead of growing a queue
/// the size of the result.
#[async_trait]
pub trait ResultSink: Send + 'static {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow;
}
