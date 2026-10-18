use serde::{Deserialize, Deserializer, Serialize};

use crate::group_name_error::GroupNameError;

/// The group a saved connection is filed under, as the user typed it
/// without the spaces around it.
///
/// A name read from disk passes the same check as one from the dialog,
/// after `from_stored` cleans it, so a name a menu or a section title
/// could not show never reaches either.
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

    /// A name read back from a file. Builds before the limits stored any
    /// name the user typed, so control characters become spaces and the
    /// name is cut to the limit rather than making the file unreadable.
    /// A blank name means no group.
    pub(crate) fn from_stored(value: &str) -> Option<Self> {
        let shown: String = value.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        let cut: String = shown.trim().chars().take(Self::MAX_CHARS).collect();
        Self::new(&cut).ok()
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Reads a saved connection's `group` through `from_stored`.
pub(crate) fn deserialize_stored<'de, D>(deserializer: D) -> Result<Option<ConnectionGroupName>, D::Error>
where
    D: Deserializer<'de>,
{
    let stored = Option::<String>::deserialize(deserializer)?;
    Ok(stored.as_deref().and_then(ConnectionGroupName::from_stored))
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
    fn a_stored_name_is_cleaned_rather_than_refused() {
        let long = "a".repeat(ConnectionGroupName::MAX_CHARS + 10);
        assert_eq!(
            ConnectionGroupName::from_stored(&long).map(String::from),
            Some("a".repeat(ConnectionGroupName::MAX_CHARS))
        );
        assert_eq!(
            ConnectionGroupName::from_stored("Work\tHome\n").map(String::from),
            Some(String::from("Work Home"))
        );
        assert_eq!(ConnectionGroupName::from_stored(" \t "), None);
        assert_eq!(ConnectionGroupName::from_stored(""), None);
    }

    #[test]
    fn group_name_try_from_and_into_string_round_trip() {
        let name = ConnectionGroupName::try_from(String::from(" Prod ")).expect("a valid name");

        assert_eq!(name.as_str(), "Prod");
        assert_eq!(String::from(name), "Prod");
    }
}
