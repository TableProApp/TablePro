// GtkSourceView's fuzzy ranking over characters rather than bytes: its strchr lookup never matches a needle outside
// ASCII, so "đơn" would not find "đơn_hàng".

use std::ops::Range;

// Each character lowercased on its own, so a letter the matcher compares one to one never becomes two, as GLib's
// casefold turns ß into ss.
pub fn casefold(needle: &str) -> String {
    needle
        .chars()
        .map(|c| {
            let mut lower = c.to_lowercase();
            let first = lower.next().unwrap_or(c);
            if lower.next().is_some() { c } else { first }
        })
        .collect()
}

// How far `haystack` is from `casefold_needle`, lower being closer; None when it does not match.
pub fn fuzzy_match(haystack: &str, casefold_needle: &str) -> Option<u32> {
    matched(haystack, casefold_needle).map(|found| found.score)
}

// Everything matches while nothing is typed.
pub fn matches_word(haystack: &str, word: &str) -> bool {
    word.is_empty() || fuzzy_match(haystack, &casefold(word)).is_some()
}

// Byte ranges of the matched characters, adjacent ones joined, for a list to mark; empty without a match.
pub fn matched_runs(haystack: &str, casefold_needle: &str) -> Vec<Range<usize>> {
    matched(haystack, casefold_needle).map_or_else(Vec::new, |found| found.runs)
}

struct Match {
    score: u32,
    runs: Vec<Range<usize>>,
}

// A skipped character costs two, a match only by case one, and every character left at the end one, so a prefix
// ranks first.
fn matched(haystack: &str, casefold_needle: &str) -> Option<Match> {
    if haystack.is_empty() {
        return None;
    }
    let mut chars = haystack.char_indices();
    let mut score: u32 = 0;
    let mut runs: Vec<Range<usize>> = Vec::new();
    for wanted in casefold_needle.chars() {
        let mut skipped: u32 = 0;
        let (at, found) = loop {
            let (at, found) = chars.next()?;
            if same_letter(found, wanted) {
                break (at, found);
            }
            skipped += 1;
        };
        score = score.saturating_add(skipped.saturating_mul(2));
        if found != wanted {
            score = score.saturating_add(1);
        }
        let end = at + found.len_utf8();
        match runs.last_mut() {
            Some(run) if run.end == at => run.end = end,
            _ => runs.push(at..end),
        }
    }
    let rest = u32::try_from(chars.count()).unwrap_or(u32::MAX);
    Some(Match {
        score: score.saturating_add(rest),
        runs,
    })
}

fn same_letter(found: char, wanted: char) -> bool {
    // The general case builds two iterators a character, which ranking a catalog of 50,000 tables feels.
    if found.is_ascii() && wanted.is_ascii() {
        return found.eq_ignore_ascii_case(&wanted);
    }
    found == wanted || found.to_lowercase().eq(wanted.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_match_ranks_prefix_higher() {
        let needle = casefold("us");

        let prefix = fuzzy_match("users", &needle).expect("a match");
        let scattered = fuzzy_match("product_status", &needle).expect("a match");

        assert!(prefix < scattered, "{prefix} is not closer than {scattered}");
        assert_eq!(fuzzy_match("orders", &needle), None);
        assert_eq!(fuzzy_match("su", &needle), None, "the order of the letters was ignored");
    }

    #[test]
    fn an_exact_case_match_ranks_above_one_by_case() {
        let needle = casefold("id");

        assert!(fuzzy_match("id", &needle) < fuzzy_match("ID", &needle));
    }

    #[test]
    fn non_ascii_needle_is_casefolded() {
        let needle = casefold("ĐƠN");

        assert_eq!(needle, "đơn");
        assert!(fuzzy_match("đơn_hàng", &needle).is_some());
        assert!(fuzzy_match("ĐƠN_HÀNG", &needle).is_some());
        assert_eq!(fuzzy_match("don_hang", &needle), None);
    }

    #[test]
    fn a_proposal_is_offered_only_for_a_word_it_matches() {
        assert!(matches_word("orders", ""));
        assert!(matches_word("orders", "ORD"));
        assert!(!matches_word("orders", "ordu"), "a proposal ranked for the last word");
    }

    #[test]
    fn an_empty_needle_matches_everything() {
        assert!(fuzzy_match("users", "").is_some());
        assert_eq!(fuzzy_match("", ""), None);
    }

    #[test]
    fn matched_runs_join_adjacent_characters() {
        assert_eq!(matched_runs("users", &casefold("US")), [Range { start: 0, end: 2 }]);
        assert_eq!(matched_runs("users", ""), Vec::<Range<usize>>::new());
        assert_eq!(matched_runs("orders", &casefold("us")), Vec::<Range<usize>>::new());
    }

    #[test]
    fn matched_runs_mark_whole_multibyte_characters() {
        let text = "bảng_đơn";
        let d = text.find('đ').expect("đ");
        let n = text.rfind('n').expect("n");

        assert_eq!(matched_runs(text, &casefold("đn")), [d..d + 2, n..n + 1]);
    }

    #[test]
    fn a_dotted_i_keeps_one_source_character() {
        assert_eq!(casefold("İ"), "İ");
        assert!(matches_word("İstanbul", "İ"));
        assert_eq!(matched_runs("İstanbul", &casefold("İst")), [Range { start: 0, end: 4 }]);
    }

    #[test]
    fn a_sharp_s_typed_finds_the_name_it_is_in() {
        assert_eq!(casefold("STRAẞE"), "straße");
        assert!(matches_word("straße_nr", "straß"));
    }
}
