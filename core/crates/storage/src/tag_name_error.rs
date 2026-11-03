#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TagNameError {
    #[error("a tag name cannot be empty")]
    Empty,
    #[error("a tag name can be at most {max} characters long")]
    TooLong { max: usize },
    #[error("a tag name cannot contain control characters")]
    ControlCharacter,
}

impl TagNameError {
    // Stable across releases, for a UI outside Rust to word the error from.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Empty => "tag_name.empty",
            Self::TooLong { .. } => "tag_name.too_long",
            Self::ControlCharacter => "tag_name.control_character",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_name_error_has_a_code_of_its_own() {
        assert_eq!(TagNameError::Empty.code(), "tag_name.empty");
        assert_eq!(TagNameError::TooLong { max: 1 }.code(), "tag_name.too_long");
        assert_eq!(TagNameError::ControlCharacter.code(), "tag_name.control_character");
    }
}
