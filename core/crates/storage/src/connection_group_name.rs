use serde::{Deserialize, Serialize};

use crate::group_name_error::GroupNameError;
use crate::name_rules::{self, NameFault};

/// The group a saved connection is filed under, its name in the form a
/// connection's name takes.
///
/// A name read from disk passes the same check as one from the dialog,
/// after `from_stored` cleans it, so a name a menu or a section title
/// could not show never reaches either.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ConnectionGroupName(String);

impl ConnectionGroupName {
    // No length limit: a macOS group name has none and has to read back unchanged.
    pub fn new(value: &str) -> Result<Self, GroupNameError> {
        match name_rules::checked(value) {
            Ok(name) => Ok(Self(name)),
            Err(NameFault::Empty) => Err(GroupNameError::Empty),
            Err(NameFault::ControlCharacter) => Err(GroupNameError::ControlCharacter),
        }
    }

    // A blank name means no group.
    pub(crate) fn from_stored(value: &str) -> Option<Self> {
        Self::new(&name_rules::cleaned(value)).ok()
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Whether the two read as one name. Two groups in one place may not.
    pub fn same_name(&self, other: &ConnectionGroupName) -> bool {
        self.0.to_lowercase() == other.0.to_lowercase()
    }
}

impl TryFrom<String> for ConnectionGroupName {
    type Error = GroupNameError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(&value)
    }
}

impl From<ConnectionGroupName> for String {
    fn from(name: ConnectionGroupName) -> Self {
        name.0
    }
}

impl std::fmt::Display for ConnectionGroupName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_name_rejects_blank_and_control_characters() {
        assert_eq!(ConnectionGroupName::new(""), Err(GroupNameError::Empty));
        assert_eq!(ConnectionGroupName::new(" \t "), Err(GroupNameError::Empty));
        assert_eq!(ConnectionGroupName::new("\u{200b}"), Err(GroupNameError::Empty));
        assert_eq!(
            ConnectionGroupName::new("Work\nHome"),
            Err(GroupNameError::ControlCharacter)
        );
        assert_eq!(
            ConnectionGroupName::new("Wo\u{7}rk"),
            Err(GroupNameError::ControlCharacter)
        );
    }

    #[test]
    fn a_name_of_any_length_is_kept_whole() {
        let name = "é".repeat(1_000);

        assert_eq!(ConnectionGroupName::new(&name).map(String::from), Ok(name.clone()));
        assert_eq!(ConnectionGroupName::from_stored(&name).map(String::from), Some(name));
    }

    #[test]
    fn a_stored_name_is_cleaned_rather_than_refused() {
        assert_eq!(
            ConnectionGroupName::from_stored("Work\tHome\n").map(String::from),
            Some(String::from("Work Home"))
        );
        assert_eq!(
            ConnectionGroupName::from_stored("Wo\u{200b}rk\u{feff}").map(String::from),
            Some(String::from("Work"))
        );
        assert_eq!(ConnectionGroupName::from_stored(" \t "), None);
        assert_eq!(ConnectionGroupName::from_stored(""), None);
        assert_eq!(
            ConnectionGroupName::from_stored("\u{200b}").map(String::from),
            Some(String::from("\\u{200b}"))
        );
    }

    #[test]
    fn group_name_try_from_and_into_string_round_trip() {
        let name = ConnectionGroupName::try_from(String::from(" Prod ")).expect("a valid name");

        assert_eq!(name.as_str(), "Prod");
        assert_eq!(String::from(name), "Prod");
    }

    #[test]
    fn names_that_read_alike_are_the_same_group() {
        let work = ConnectionGroupName::new("Work").expect("a name");

        assert!(work.same_name(&ConnectionGroupName::new("wo\u{200b}rk").expect("a name")));
        assert!(!work.same_name(&ConnectionGroupName::new("Home").expect("a name")));
    }
}
