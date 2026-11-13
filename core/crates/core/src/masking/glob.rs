use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

// `*` matches any run of characters and `?` exactly one, ignoring case. As Swift compares a String's Characters:
// lower-cased in full, by extended grapheme cluster, and equal when canonically equivalent.
pub fn glob_matches(pattern: &str, text: &str) -> bool {
    let pattern = clusters(pattern);
    let text = clusters(text);
    let (mut at_pattern, mut at_text) = (0, 0);
    let mut star: Option<usize> = None;
    let mut resume = 0;
    while at_text < text.len() {
        match pattern.get(at_pattern).map(String::as_str) {
            Some(cluster) if cluster == "?" || cluster == text[at_text] => {
                at_pattern += 1;
                at_text += 1;
            }
            Some("*") => {
                star = Some(at_pattern);
                resume = at_text;
                at_pattern += 1;
            }
            _ => match star {
                Some(star) => {
                    at_pattern = star + 1;
                    resume += 1;
                    at_text = resume;
                }
                None => return false,
            },
        }
    }
    pattern[at_pattern..].iter().all(|cluster| cluster == "*")
}

fn clusters(text: &str) -> Vec<String> {
    text.to_lowercase()
        .graphemes(true)
        .map(|cluster| cluster.nfc().collect())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_and_question_mark_match_runs_and_single_characters() {
        assert!(glob_matches("*", ""));
        assert!(glob_matches("*", "anything"));
        assert!(glob_matches("*email*", "contact_email_2"));
        assert!(glob_matches("e?ail", "email"));
        assert!(!glob_matches("e?ail", "emmail"));
        assert!(glob_matches("a*b*c", "aXXbYYc"));
        assert!(!glob_matches("a*b*c", "aXXbYY"));
        assert!(glob_matches("", ""));
        assert!(!glob_matches("", "a"));
        assert!(!glob_matches("a", ""));
    }

    #[test]
    fn case_is_ignored_in_full_unicode_but_not_folded() {
        assert!(glob_matches("EMAIL", "email"));
        assert!(glob_matches("ÉTÉ", "été"));
        assert!(!glob_matches("straße", "STRASSE"));
    }

    #[test]
    fn a_character_is_a_grapheme_cluster_compared_by_canonical_equivalence() {
        let decomposed = "e\u{301}";
        assert!(glob_matches("?", decomposed));
        assert!(glob_matches("caf?", "cafe\u{301}"));
        assert!(glob_matches("café", "cafe\u{301}"));
        assert!(!glob_matches("??", decomposed));
        assert!(glob_matches("?", "👨‍👩‍👧"));
    }
}
