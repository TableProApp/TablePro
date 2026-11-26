#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Success,
    Error(String),
    Cancelled,
}

impl Outcome {
    // The `success`, `cancelled` and `error` columns.
    pub(super) fn columns(&self) -> (i64, i64, Option<&str>) {
        match self {
            Self::Success => (1, 0, None),
            Self::Error(message) => (0, 0, Some(message.as_str())),
            Self::Cancelled => (0, 1, None),
        }
    }
}
