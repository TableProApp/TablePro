/// What the find bar's count label says about the search.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct FindStatus {
    /// `None` while the search is still counting, or with nothing to
    /// search for.
    pub occurrences: Option<u32>,
    /// The match the selection is on, counted from 1. `None` when the
    /// selection is on none, or the search has not reached it yet.
    pub position: Option<u32>,
    pub regex_error: Option<String>,
}

impl FindStatus {
    /// From GtkSourceSearchContext's counts, where -1 means not counted
    /// yet and a position of 0 means the selection is on no match.
    pub(crate) fn from_counts(occurrences: i32, position: i32, regex_error: Option<String>) -> Self {
        Self {
            occurrences: u32::try_from(occurrences).ok(),
            position: u32::try_from(position).ok().filter(|position| *position > 0),
            regex_error,
        }
    }

    pub(crate) fn label(&self) -> String {
        // The entry itself says what is wrong with the pattern.
        if self.regex_error.is_some() {
            return String::new();
        }
        match self.occurrences {
            None => String::new(),
            Some(0) => crate::i18n::gettext("No results"),
            Some(count) => crate::i18n::gettext_f(
                "{position} of {count}",
                &[
                    ("position", &self.position.unwrap_or(0).to_string()),
                    ("count", &count.to_string()),
                ],
            ),
        }
    }

    /// What a screen reader hears once the search settles: the count, or
    /// what is wrong with the pattern, which the label leaves out.
    pub(crate) fn announcement(&self) -> Option<String> {
        if let Some(error) = &self.regex_error {
            return Some(error.clone());
        }
        Some(self.label()).filter(|label| !label.is_empty())
    }

    /// Whether there is a match to replace, with its count known.
    pub(crate) fn has_matches(&self) -> bool {
        self.regex_error.is_none() && self.occurrences.is_some_and(|count| count > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_status_label_counting_empty_and_position() {
        assert_eq!(FindStatus::from_counts(-1, -1, None).label(), "", "while counting");
        assert_eq!(FindStatus::default().label(), "", "with nothing to search for");
        assert_eq!(FindStatus::from_counts(0, 0, None).label(), "No results");
        assert_eq!(FindStatus::from_counts(3, 2, None).label(), "2 of 3");
        assert_eq!(
            FindStatus::from_counts(3, 0, None).label(),
            "0 of 3",
            "the selection is on no match"
        );
        assert_eq!(
            FindStatus::from_counts(0, 0, Some("missing )".to_owned())).label(),
            "",
            "a bad pattern"
        );
    }

    #[test]
    fn the_announcement_is_the_count_or_the_pattern_error() {
        assert_eq!(
            FindStatus::from_counts(3, 2, None).announcement().as_deref(),
            Some("2 of 3")
        );
        assert_eq!(
            FindStatus::from_counts(0, 0, None).announcement().as_deref(),
            Some("No results")
        );
        assert_eq!(
            FindStatus::from_counts(-1, -1, None).announcement(),
            None,
            "while counting"
        );
        assert_eq!(
            FindStatus::from_counts(0, 0, Some("missing )".to_owned()))
                .announcement()
                .as_deref(),
            Some("missing )")
        );
    }

    #[test]
    fn only_a_counted_match_can_be_replaced() {
        assert!(FindStatus::from_counts(2, 1, None).has_matches());
        assert!(!FindStatus::from_counts(-1, -1, None).has_matches());
        assert!(!FindStatus::from_counts(0, 0, None).has_matches());
        assert!(!FindStatus::from_counts(2, 0, Some("bad".to_owned())).has_matches());
    }
}
