// The messages are also what a connection list with such a name on disk is refused with.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GroupNameError {
    #[error("a group name cannot be empty")]
    Empty,
    #[error("a group name cannot contain control characters")]
    ControlCharacter,
}

impl GroupNameError {
    // Stable across releases, for a UI outside Rust to word the error from.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Empty => "group_name.empty",
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
        assert_eq!(GroupNameError::ControlCharacter.code(), "group_name.control_character");
    }
}
