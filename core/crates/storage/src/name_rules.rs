//! The rules a connection's, a group's and a tag's name follow, shared so
//! they cannot drift apart.

use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NameFault {
    Empty,
    ControlCharacter,
}

/// `value` as [`shown`] gives it, when it is a name a menu, a row and a
/// section title can all show.
pub(crate) fn checked(value: &str) -> Result<String, NameFault> {
    let name = shown(value);
    if name.is_empty() {
        return Err(NameFault::Empty);
    }
    // A typed name is refused for one rather than shown with a space.
    if value.trim().chars().any(char::is_control) {
        return Err(NameFault::ControlCharacter);
    }
    Ok(name)
}

// A file is never refused for what an earlier build let the user type.
pub(crate) fn cleaned(value: &str) -> String {
    let name = shown(value);
    if !name.is_empty() {
        return name;
    }
    // Older builds accepted names made only of invisible characters.
    // Keep the library readable and give those names something to show.
    let old: String = value.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    old.trim().chars().flat_map(char::escape_default).collect()
}

/// A name as the list shows it: characters that show as nothing dropped,
/// control characters and every other space as a plain space, no blanks
/// around it, and each letter in its composed form. Two names that read
/// the same have the same form, so one cannot pass for the other.
pub(crate) fn shown(value: &str) -> String {
    let visible: String = value
        .chars()
        .filter(|c| !tablepro_core::unicode_blank::is_default_ignorable(*c))
        .map(|c| if c.is_control() || c.is_whitespace() { ' ' } else { c })
        .collect();
    visible.trim().nfc().collect()
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
    fn a_shown_name_has_one_space_and_one_form_of_each_letter() {
        for lookalike in [
            "staging\u{a0}db",
            "staging\u{2007}db",
            "staging\u{3000}db",
            "staging\u{2028}db",
        ] {
            assert_eq!(shown(lookalike), "staging db", "{lookalike:?}");
        }
        assert_eq!(shown("Cafe\u{301} prod"), "Caf\u{e9} prod");
        assert_eq!(shown("Caf\u{e9} prod"), "Caf\u{e9} prod");
    }

    #[test]
    fn a_name_is_trimmed_and_checked_in_characters() {
        assert_eq!(checked("  Work "), Ok("Work".to_owned()));
        assert_eq!(checked("éééé"), Ok("éééé".to_owned()));
        assert_eq!(checked("e\u{301}e\u{301}e\u{301}e\u{301}"), Ok("\u{e9}".repeat(4)));
        assert_eq!(checked(" \t "), Err(NameFault::Empty));
        assert_eq!(checked("\u{200b}"), Err(NameFault::Empty));
        assert_eq!(checked("a\nb"), Err(NameFault::ControlCharacter));
    }

    #[test]
    fn a_checked_name_drops_what_cannot_be_seen() {
        assert_eq!(checked("pr\u{200b}od\u{feff}"), Ok("prod".to_owned()));
        assert_eq!(checked("a\u{a0}b"), Ok("a b".to_owned()));
    }

    #[test]
    fn a_stored_name_loses_control_characters() {
        assert_eq!(cleaned("Work\tHome\n"), "Work Home");
        assert_eq!(cleaned("abcdef"), "abcdef");
        assert_eq!(cleaned(" \u{7} "), "");
        assert_eq!(cleaned("pro\u{200b}d\u{a0}x"), "prod x");
    }

    #[test]
    fn a_stored_invisible_name_is_visible_without_accepting_a_new_one() {
        assert_eq!(cleaned(" \u{200b}\u{feff} "), "\\u{200b}\\u{feff}");
        assert_eq!(checked("\u{200b}\u{feff}"), Err(NameFault::Empty));
        assert_eq!(cleaned(" \t\n "), "");
    }
}
