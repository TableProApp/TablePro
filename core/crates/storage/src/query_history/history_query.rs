use std::time::SystemTime;

use uuid::Uuid;

use super::StatusFilter;
use super::search_fold::fold;

/// The trigram index has nothing to match a shorter term against.
const TRIGRAM_LENGTH: usize = 3;

/// What the history is searched for. Every term has to appear in the
/// query, anywhere and in any case.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HistoryQuery {
    terms: Vec<String>,
    pub connection: Option<Uuid>,
    pub status: StatusFilter,
    pub executed_after: Option<SystemTime>,
}

/// One term as SQLite is asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum TermMatch {
    /// An FTS5 string: a quoted phrase in which every character is
    /// literal, operators and quotes included.
    Trigram(String),
    /// Too short for the trigram index, so a scan of the folded text.
    Substring(String),
}

impl HistoryQuery {
    /// The terms are the input's whitespace-separated words.
    pub fn from_input(input: &str) -> Self {
        Self {
            terms: fold(input).split_whitespace().map(str::to_owned).collect(),
            ..Self::default()
        }
    }

    pub fn terms(&self) -> &[String] {
        &self.terms
    }

    pub(super) fn term_matches(&self) -> impl Iterator<Item = TermMatch> + '_ {
        self.terms.iter().map(|term| {
            if term.chars().count() >= TRIGRAM_LENGTH {
                TermMatch::Trigram(format!("\"{}\"", term.replace('"', "\"\"")))
            } else {
                TermMatch::Substring(term.clone())
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_is_folded_and_split_on_whitespace() {
        let query = HistoryQuery::from_input("  SELECT\tÉlèves \n x ");

        assert_eq!(query.terms(), ["select", "élèves", "x"]);
    }

    #[test]
    fn a_quote_in_a_long_term_is_doubled_inside_the_phrase() {
        let query = HistoryQuery::from_input("say\"hi");

        let matches: Vec<TermMatch> = query.term_matches().collect();

        assert_eq!(matches, vec![TermMatch::Trigram("\"say\"\"hi\"".to_owned())]);
    }

    #[test]
    fn length_is_counted_in_characters_not_bytes() {
        let query = HistoryQuery::from_input("éé");

        let matches: Vec<TermMatch> = query.term_matches().collect();

        assert_eq!(matches, vec![TermMatch::Substring("éé".to_owned())]);
    }
}
