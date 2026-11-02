use serde::{Deserialize, Deserializer, Serialize};

use crate::name_rules::{self, NameFault};
use crate::tag_name_error::TagNameError;

/// A tag's name as the user typed it, without the spaces around it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ConnectionTagName(String);

impl ConnectionTagName {
    // A tag sits beside the name in a connection's row, so it stays short.
    pub const MAX_CHARS: usize = 32;

    pub fn new(value: &str) -> Result<Self, TagNameError> {
        match name_rules::checked(value, Self::MAX_CHARS) {
            Ok(name) => Ok(Self(name.to_owned())),
            Err(NameFault::Empty) => Err(TagNameError::Empty),
            Err(NameFault::TooLong) => Err(TagNameError::TooLong { max: Self::MAX_CHARS }),
            Err(NameFault::ControlCharacter) => Err(TagNameError::ControlCharacter),
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    // Two tags whose names differ only in case would read as one.
    pub fn same_name(&self, other: &str) -> bool {
        self.key() == other.trim().to_lowercase()
    }

    /// The name as two tags are told apart by.
    pub(crate) fn key(&self) -> String {
        self.0.to_lowercase()
    }
}

/// A tag's name read back from a file, cleaned as a group's is. A name
/// left blank is refused: a tag nobody can see cannot be told apart.
pub(crate) fn deserialize_stored<'de, D>(deserializer: D) -> Result<ConnectionTagName, D::Error>
where
    D: Deserializer<'de>,
{
    let stored = String::deserialize(deserializer)?;
    ConnectionTagName::new(&name_rules::cleaned(&stored, ConnectionTagName::MAX_CHARS))
        .map_err(serde::de::Error::custom)
}

impl TryFrom<String> for ConnectionTagName {
    type Error = TagNameError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(&value)
    }
}

impl From<ConnectionTagName> for String {
    fn from(name: ConnectionTagName) -> Self {
        name.0
    }
}

impl std::fmt::Display for ConnectionTagName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tag_name_follows_the_name_rules() {
        assert_eq!(
            ConnectionTagName::new(" prod ").map(String::from),
            Ok("prod".to_owned())
        );
        assert_eq!(ConnectionTagName::new("  "), Err(TagNameError::Empty));
        assert_eq!(
            ConnectionTagName::new(&"t".repeat(ConnectionTagName::MAX_CHARS + 1)),
            Err(TagNameError::TooLong {
                max: ConnectionTagName::MAX_CHARS
            })
        );
        assert_eq!(ConnectionTagName::new("a\u{7}"), Err(TagNameError::ControlCharacter));
    }

    #[test]
    fn names_that_differ_only_in_case_are_the_same_tag() {
        let name = ConnectionTagName::new("Production").expect("a name");

        assert!(name.same_name("production"));
        assert!(name.same_name(" PRODUCTION "));
        assert!(!name.same_name("prod"));
    }

    #[derive(Debug, Deserialize)]
    struct Stored {
        #[serde(deserialize_with = "deserialize_stored")]
        name: ConnectionTagName,
    }

    #[test]
    fn a_stored_name_is_cleaned_and_a_blank_one_refused() {
        let long = "x".repeat(ConnectionTagName::MAX_CHARS + 5);
        let read: Stored = serde_json::from_str(&format!(r#"{{"name":"{long}"}}"#)).expect("a long name");
        assert_eq!(read.name.as_str(), "x".repeat(ConnectionTagName::MAX_CHARS));

        let read: Stored = serde_json::from_str(r#"{"name":"a\tb"}"#).expect("a control character");
        assert_eq!(read.name.as_str(), "a b");

        assert!(serde_json::from_str::<Stored>(r#"{"name":" \n "}"#).is_err());
    }
}
