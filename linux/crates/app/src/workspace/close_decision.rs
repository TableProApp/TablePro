/// How a close ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseDecision {
    /// Nothing is left to lose, or the user agreed to lose it.
    Approved,
    Cancelled,
}
