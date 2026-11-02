#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TagNameError {
    #[error("a tag name cannot be empty")]
    Empty,
    #[error("a tag name can be at most {max} characters long")]
    TooLong { max: usize },
    #[error("a tag name cannot contain control characters")]
    ControlCharacter,
}
