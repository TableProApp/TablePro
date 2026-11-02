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

impl GroupNameError {
    /// A name for the variant that stays the same across releases, for a
    /// UI outside Rust to word the error from.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Empty => "group_name.empty",
            Self::TooLong { .. } => "group_name.too_long",
            Self::ControlCharacter => "group_name.control_character",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_name_error_has_a_code_of_its_own() {
        assert_eq!(GroupNameError::Empty.code(), "group_name.empty");
        assert_eq!(GroupNameError::TooLong { max: 64 }.code(), "group_name.too_long");
        assert_eq!(GroupNameError::ControlCharacter.code(), "group_name.control_character");
    }
}
