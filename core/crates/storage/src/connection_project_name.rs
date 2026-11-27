use serde::{Deserialize, Serialize};

use crate::name_rules::{self, NameFault};
use crate::project_name_error::ProjectNameError;

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ConnectionProjectName(String);

impl ConnectionProjectName {
    // No length limit, as a group name has none.
    pub fn new(value: &str) -> Result<Self, ProjectNameError> {
        match name_rules::checked(value) {
            Ok(name) => Ok(Self(name)),
            Err(NameFault::Empty) => Err(ProjectNameError::Empty),
            Err(NameFault::ControlCharacter) => Err(ProjectNameError::ControlCharacter),
        }
    }

    pub(crate) fn from_stored(value: &str) -> Result<Self, ProjectNameError> {
        Self::new(&name_rules::cleaned(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn same_name(&self, other: &ConnectionProjectName) -> bool {
        self.key() == other.key()
    }

    // The name two projects are told apart by.
    pub(crate) fn key(&self) -> String {
        self.0.to_lowercase()
    }
}

impl TryFrom<String> for ConnectionProjectName {
    type Error = ProjectNameError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(&value)
    }
}

impl From<ConnectionProjectName> for String {
    fn from(name: ConnectionProjectName) -> Self {
        name.0
    }
}

impl std::fmt::Display for ConnectionProjectName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(value: &str) -> ConnectionProjectName {
        ConnectionProjectName::new(value).expect("a project name")
    }

    #[test]
    fn a_project_name_rejects_blank_and_control_characters() {
        assert_eq!(ConnectionProjectName::new(""), Err(ProjectNameError::Empty));
        assert_eq!(ConnectionProjectName::new(" \t "), Err(ProjectNameError::Empty));
        assert_eq!(ConnectionProjectName::new("\u{200b}"), Err(ProjectNameError::Empty));
        assert_eq!(
            ConnectionProjectName::new("Ac\nme"),
            Err(ProjectNameError::ControlCharacter)
        );
    }

    #[test]
    fn a_project_name_is_trimmed_and_composed() {
        assert_eq!(name("  Acme ").as_str(), "Acme");
        assert_eq!(name("Cafe\u{301}").as_str(), "Caf\u{e9}");
    }

    #[test]
    fn names_that_read_alike_are_the_same_project() {
        let acme = name("Acme");

        assert!(acme.same_name(&name(" ACME ")));
        assert!(acme.same_name(&name("ac\u{200b}me")));
        assert!(name("Caf\u{e9}").same_name(&name("CAFE\u{301}")));
        assert!(!acme.same_name(&name("Acme 2")));
    }

    #[test]
    fn a_stored_name_is_cleaned_and_a_blank_one_refused() {
        assert_eq!(
            ConnectionProjectName::from_stored("Ac\tme\n").map(String::from),
            Ok("Ac me".to_owned())
        );
        assert_eq!(ConnectionProjectName::from_stored(" \n "), Err(ProjectNameError::Empty));
    }
}
