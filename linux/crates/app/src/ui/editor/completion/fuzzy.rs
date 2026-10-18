//! GtkSourceView's fuzzy ranking, over characters rather than bytes.
//!
//! `gtk_source_completion_fuzzy_match` looks each needle character up
//! with `strchr`, so a needle with a character outside ASCII never
//! matches: "đơn" does not find "đơn_hàng". This keeps its scoring and
//! compares whole characters.

use std::ops::Range;

use gtk4::glib;
use gtk4::pango;

/// The needle in the form the matcher compares against.
pub fn casefold(needle: &str) -> String {
    glib::casefold(needle).into()
}

/// How far `haystack` is from `casefold_needle`, lower being closer, or
/// `None` when it does not match.
pub fn fuzzy_match(haystack: &str, casefold_needle: &str) -> Option<u32> {
    matched(haystack, casefold_needle).map(|found| found.score)
}

/// Bold for the characters of `haystack` the needle matched.
pub fn highlight(haystack: &str, casefold_needle: &str) -> Option<pango::AttrList> {
    let found = matched(haystack, casefold_needle)?;
    if found.runs.is_empty() {
        return None;
    }
    let attrs = pango::AttrList::new();
    for run in found.runs {
        let mut bold = pango::AttrInt::new_weight(pango::Weight::Bold);
        bold.set_start_index(u32::try_from(run.start).unwrap_or(u32::MAX));
        bold.set_end_index(u32::try_from(run.end).unwrap_or(u32::MAX));
        attrs.insert(bold);
    }
    Some(attrs)
}

struct Match {
    score: u32,
    /// Byte ranges of the matched characters, adjacent ones joined.
    runs: Vec<Range<usize>>,
}

/// Each needle character at its first place after the last one. A
/// character skipped costs two, a match only by case one, and every
/// character left at the end one, so a prefix ranks first.
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
    fn an_empty_needle_matches_everything() {
        assert!(fuzzy_match("users", "").is_some());
        assert_eq!(fuzzy_match("", ""), None);
    }

    #[test]
    fn highlight_returns_attrs() {
        let attrs = highlight("users", &casefold("US")).expect("an attribute list");

        let runs: Vec<(u32, u32)> = attrs
            .attributes()
            .iter()
            .map(|attr| (attr.start_index(), attr.end_index()))
            .collect();
        assert_eq!(runs, [(0, 2)]);
    }

    #[test]
    fn highlight_marks_whole_multibyte_characters() {
        let attrs = highlight("bảng_đơn", &casefold("đn")).expect("an attribute list");

        let runs: Vec<(u32, u32)> = attrs
            .attributes()
            .iter()
            .map(|attr| (attr.start_index(), attr.end_index()))
            .collect();
        let text = "bảng_đơn";
        let d = u32::try_from(text.find('đ').expect("đ")).expect("a short text");
        let n = u32::try_from(text.rfind('n').expect("n")).expect("a short text");
        assert_eq!(runs, [(d, d + 2), (n, n + 1)]);
    }
}
