use serde::{Deserialize, Serialize};

use crate::group_name_error::GroupNameError;

/// The group a saved connection is filed under, as the user typed it
/// without the spaces around it.
///
/// Read from disk through the same check as from the dialog, so a name
/// a menu or a section title could not show never reaches either.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ConnectionGroupName(String);

impl ConnectionGroupName {
    /// Long enough for any real folder name, short enough for a menu.
    pub const MAX_CHARS: usize = 64;

    pub fn new(value: &str) -> Result<Self, GroupNameError> {
        let name = value.trim();
        if name.is_empty() {
            return Err(GroupNameError::Empty);
        }
        if name.chars().count() > Self::MAX_CHARS {
            return Err(GroupNameError::TooLong { max: Self::MAX_CHARS });
        }
        if name.chars().any(char::is_control) {
            return Err(GroupNameError::ControlCharacter);
        }
        Ok(Self(name.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
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
    fn group_name_rejects_blank_long_and_control_characters() {
        assert_eq!(ConnectionGroupName::new(""), Err(GroupNameError::Empty));
        assert_eq!(ConnectionGroupName::new(" \t "), Err(GroupNameError::Empty));
        assert_eq!(
            ConnectionGroupName::new(&"a".repeat(ConnectionGroupName::MAX_CHARS + 1)),
            Err(GroupNameError::TooLong {
                max: ConnectionGroupName::MAX_CHARS
            })
        );
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
    fn the_limit_counts_characters_not_bytes() {
        let name = "é".repeat(ConnectionGroupName::MAX_CHARS);

        assert_eq!(ConnectionGroupName::new(&name).map(String::from), Ok(name));
    }

    #[test]
    fn group_name_try_from_and_into_string_round_trip() {
        let name = ConnectionGroupName::try_from(String::from(" Prod ")).expect("a valid name");

        assert_eq!(name.as_str(), "Prod");
        assert_eq!(String::from(name), "Prod");
    }
}
