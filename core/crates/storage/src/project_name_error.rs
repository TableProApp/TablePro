// The messages are also what a connection list with such a name on disk is refused with.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProjectNameError {
    #[error("a project name cannot be empty")]
    Empty,
    #[error("a project name cannot contain control characters")]
    ControlCharacter,
}

impl ProjectNameError {
    // Stable across releases, for a UI outside Rust to word the error from.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Empty => "project_name.empty",
            Self::ControlCharacter => "project_name.control_character",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_name_error_has_a_code_of_its_own() {
        assert_eq!(ProjectNameError::Empty.code(), "project_name.empty");
        assert_eq!(
            ProjectNameError::ControlCharacter.code(),
            "project_name.control_character"
        );
    }
}
