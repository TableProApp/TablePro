use serde::{Deserialize, Serialize};

use crate::group_name_error::GroupNameError;
use crate::name_rules::{self, NameFault};

// A typed name passes `new`; a stored one is kept as it was written and read through `shown` and `same_name`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
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

    // A library moving in or a pull keeps what another app let the person type, blank included.
    pub fn from_stored(value: &str) -> Self {
        Self(value.to_owned())
    }

    // For a name from outside the person's own library, such as a file: cleaned, and None when blank.
    pub fn cleaned_from(value: &str) -> Option<Self> {
        Self::new(&name_rules::cleaned(value)).ok()
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn shown(&self) -> String {
        name_rules::cleaned(&self.0)
    }

    // Two groups in one place may not read as one name.
    pub fn same_name(&self, other: &ConnectionGroupName) -> bool {
        name_rules::shown(&self.0).to_lowercase() == name_rules::shown(&other.0).to_lowercase()
    }
}

impl From<String> for ConnectionGroupName {
    fn from(value: String) -> Self {
        Self(value)
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
        assert_eq!(String::from(ConnectionGroupName::from_stored(&name)), name);
    }

    #[test]
    fn a_name_from_outside_is_cleaned_rather_than_refused() {
        assert_eq!(
            ConnectionGroupName::cleaned_from("Work\tHome\n").map(String::from),
            Some(String::from("Work Home"))
        );
        assert_eq!(
            ConnectionGroupName::cleaned_from("Wo\u{200b}rk\u{feff}").map(String::from),
            Some(String::from("Work"))
        );
        assert_eq!(ConnectionGroupName::cleaned_from(" \t "), None);
        assert_eq!(ConnectionGroupName::cleaned_from(""), None);
        assert_eq!(
            ConnectionGroupName::cleaned_from("\u{200b}").map(String::from),
            Some(String::from("\\u{200b}"))
        );
    }

    #[test]
    fn a_stored_name_is_kept_as_written_and_shown_cleaned() {
        for raw in [" Work\tHome ", "", " \u{200b}", "Wo\u{7}rk"] {
            let name = ConnectionGroupName::from_stored(raw);

            assert_eq!(name.as_str(), raw);
            assert_eq!(String::from(name.clone()), raw);
            assert_eq!(
                serde_json::from_str::<ConnectionGroupName>(&serde_json::to_string(&name).expect("json"))
                    .expect("read"),
                name
            );
        }
        assert_eq!(ConnectionGroupName::from_stored(" Work\tHome ").shown(), "Work Home");
        assert!(
            ConnectionGroupName::from_stored(" work ").same_name(&ConnectionGroupName::from_stored("Wo\u{200b}rk"))
        );
    }

    #[test]
    fn names_that_read_alike_are_the_same_group() {
        let work = ConnectionGroupName::new("Work").expect("a name");

        assert!(work.same_name(&ConnectionGroupName::new("wo\u{200b}rk").expect("a name")));
        assert!(!work.same_name(&ConnectionGroupName::new("Home").expect("a name")));
    }
}
