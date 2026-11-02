#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Success,
    Error(String),
    Cancelled,
}
