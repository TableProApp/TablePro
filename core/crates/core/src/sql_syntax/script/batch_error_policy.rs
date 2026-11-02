#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BatchErrorPolicy {
    StopScript,
    ContinueNextBatch,
}
