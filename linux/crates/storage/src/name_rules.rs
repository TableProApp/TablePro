//! The rules a group's or a tag's name follows, shared so the two cannot
//! drift apart.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NameFault {
    Empty,
    TooLong,
    ControlCharacter,
}

/// `value` without the spaces around it, when it is a name a menu, a row
/// and a section title can all show.
pub(crate) fn checked(value: &str, max: usize) -> Result<&str, NameFault> {
    let name = value.trim();
    if name.is_empty() {
        return Err(NameFault::Empty);
    }
    if name.chars().count() > max {
        return Err(NameFault::TooLong);
    }
    if name.chars().any(char::is_control) {
        return Err(NameFault::ControlCharacter);
    }
    Ok(name)
}

/// A name read back from a file, with control characters turned into
/// spaces and cut to the limit, since a file is never refused for what
/// an earlier build let the user type.
pub(crate) fn cleaned(value: &str, max: usize) -> String {
    let shown: String = value.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    shown.trim().chars().take(max).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_is_trimmed_and_checked_in_characters() {
        assert_eq!(checked("  Work ", 4), Ok("Work"));
        assert_eq!(checked("éééé", 4), Ok("éééé"));
        assert_eq!(checked("ééééé", 4), Err(NameFault::TooLong));
        assert_eq!(checked(" \t ", 4), Err(NameFault::Empty));
        assert_eq!(checked("a\nb", 4), Err(NameFault::ControlCharacter));
    }

    #[test]
    fn a_stored_name_loses_control_characters_and_the_excess() {
        assert_eq!(cleaned("Work\tHome\n", 64), "Work Home");
        assert_eq!(cleaned("abcdef", 4), "abcd");
        assert_eq!(cleaned(" \u{7} ", 4), "");
    }
}
