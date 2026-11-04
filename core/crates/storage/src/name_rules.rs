//! The rules a group's or a tag's name follows, shared so the two cannot
//! drift apart.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NameFault {
    Empty,
    ControlCharacter,
}

pub(crate) fn checked(value: &str) -> Result<&str, NameFault> {
    let name = value.trim();
    if name.is_empty() {
        return Err(NameFault::Empty);
    }
    if name.chars().any(char::is_control) {
        return Err(NameFault::ControlCharacter);
    }
    Ok(name)
}

// A file is never refused for what an earlier build let the user type.
pub(crate) fn cleaned(value: &str) -> String {
    let shown: String = value.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    shown.trim().to_owned()
}

/// A connection's name as the list shows it: control characters as
/// spaces, characters that show as nothing dropped, and no blanks around
/// it. Two names that read the same have the same form, so one cannot
/// pass for the other.
pub(crate) fn shown(value: &str) -> String {
    let visible: String = value
        .chars()
        .filter(|c| !tablepro_core::unicode_blank::is_default_ignorable(*c))
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    visible.trim().to_owned()
}

/// A stored name, read as [`shown`] gives it.
pub(crate) fn deserialize_shown<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    let name = <String as serde::Deserialize>::deserialize(deserializer)?;
    Ok(shown(&name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shown_name_drops_what_cannot_be_seen() {
        for lookalike in [
            "production",
            " production ",
            "production\u{a0}",
            "pro\u{200b}duction",
            "\u{feff}production",
            "production\u{2060}\t",
        ] {
            assert_eq!(shown(lookalike), "production", "{lookalike:?}");
        }
        assert_eq!(shown("prod\nuction"), "prod uction");
    }

    #[test]
    fn a_name_is_trimmed_and_checked() {
        assert_eq!(checked("  Work "), Ok("Work"));
        assert_eq!(checked(" \t "), Err(NameFault::Empty));
        assert_eq!(checked("a\nb"), Err(NameFault::ControlCharacter));
    }

    #[test]
    fn a_stored_name_loses_control_characters() {
        assert_eq!(cleaned("Work\tHome\n"), "Work Home");
        assert_eq!(cleaned(" \u{7} "), "");
    }
}
