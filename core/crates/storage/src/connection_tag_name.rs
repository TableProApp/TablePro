use serde::{Deserialize, Serialize};

use crate::name_rules::{self, NameFault};
use crate::tag_name_error::TagNameError;

// A typed name passes `new`; a stored one is kept as it was written and read through `shown` and `same_name`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
pub struct ConnectionTagName(String);

impl ConnectionTagName {
    // A tag sits beside the name in a connection's row, so it stays short.
    pub const MAX_CHARS: usize = 32;

    pub fn new(value: &str) -> Result<Self, TagNameError> {
        match name_rules::checked(value) {
            Ok(name) if name.chars().count() > Self::MAX_CHARS => Err(TagNameError::TooLong { max: Self::MAX_CHARS }),
            Ok(name) => Ok(Self(name)),
            Err(NameFault::Empty) => Err(TagNameError::Empty),
            Err(NameFault::ControlCharacter) => Err(TagNameError::ControlCharacter),
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn shown(&self) -> String {
        name_rules::cleaned(&self.0)
    }

    // Two tags whose names differ only in case would read as one.
    pub fn same_name(&self, other: &str) -> bool {
        self.key() == name_rules::shown(other).to_lowercase()
    }

    pub(crate) fn key(&self) -> String {
        name_rules::shown(&self.0).to_lowercase()
    }

    // A library moving in or a pull keeps what another app let the person type, of any length.
    pub fn from_stored(value: &str) -> Self {
        Self(value.to_owned())
    }

    // For a name from outside the person's own library, such as a file.
    pub(crate) fn cleaned_from(value: &str) -> Result<Self, TagNameError> {
        Self::new(
            &name_rules::cleaned(value)
                .chars()
                .take(Self::MAX_CHARS)
                .collect::<String>(),
        )
    }
}

impl From<String> for ConnectionTagName {
    fn from(value: String) -> Self {
        Self(value)
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
        assert_eq!(ConnectionTagName::new("\u{200b}"), Err(TagNameError::Empty));
        assert_eq!(
            ConnectionTagName::new(&"t".repeat(ConnectionTagName::MAX_CHARS + 1)),
            Err(TagNameError::TooLong {
                max: ConnectionTagName::MAX_CHARS
            })
        );
        assert_eq!(ConnectionTagName::new("a\u{7}"), Err(TagNameError::ControlCharacter));
        assert_eq!(
            ConnectionTagName::new("prod\u{200b}").map(String::from),
            Ok("prod".to_owned())
        );
    }

    #[test]
    fn the_limit_counts_characters_not_bytes() {
        let name = "é".repeat(ConnectionTagName::MAX_CHARS);

        assert_eq!(ConnectionTagName::new(&name).map(String::from), Ok(name));
    }

    #[test]
    fn names_that_differ_only_in_case_are_the_same_tag() {
        let name = ConnectionTagName::new("Production").expect("a name");

        assert!(name.same_name("production"));
        assert!(name.same_name(" PRODUCTION "));
        assert!(name.same_name("produc\u{200b}tion"));
        assert!(!name.same_name("prod"));
    }

    #[test]
    fn a_name_from_outside_is_cleaned_and_a_blank_one_refused() {
        let long = "x".repeat(ConnectionTagName::MAX_CHARS + 5);
        let read = ConnectionTagName::cleaned_from(&long).expect("a long name");
        assert_eq!(read.as_str(), "x".repeat(ConnectionTagName::MAX_CHARS));

        let read = ConnectionTagName::cleaned_from("a\tb").expect("a control character");
        assert_eq!(read.as_str(), "a b");

        let read = ConnectionTagName::cleaned_from("production\u{200b}").expect("a blank");
        assert_eq!(read.as_str(), "production");

        assert_eq!(ConnectionTagName::cleaned_from(" \n "), Err(TagNameError::Empty));
    }

    #[test]
    fn a_stored_name_is_kept_as_written() {
        let long = "x".repeat(ConnectionTagName::MAX_CHARS + 5);
        for raw in [long.as_str(), " Prod ", ""] {
            let name = ConnectionTagName::from_stored(raw);

            assert_eq!(name.as_str(), raw);
            assert_eq!(
                serde_json::from_str::<ConnectionTagName>(&serde_json::to_string(&name).expect("json")).expect("read"),
                name
            );
        }
        assert!(ConnectionTagName::from_stored(" Prod ").same_name("prod"));
        assert_eq!(ConnectionTagName::from_stored(" Prod\t").shown(), "Prod");
    }
}
