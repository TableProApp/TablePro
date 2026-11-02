/// Why a group name cannot be used. The messages are also what a
/// connection list with such a name on disk is refused with.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GroupNameError {
    #[error("a group name cannot be empty")]
    Empty,
    #[error("a group name can be at most {max} characters long")]
    TooLong { max: usize },
    #[error("a group name cannot contain control characters")]
    ControlCharacter,
}
