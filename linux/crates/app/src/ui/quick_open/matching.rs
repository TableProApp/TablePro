#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Rank(u8, usize);

pub(super) fn normalize(text: &str) -> Vec<char> {
    text.chars().flat_map(char::to_lowercase).collect()
}

pub(super) fn rank(typed: &[char], name: &[char]) -> Option<Rank> {
    if typed.is_empty() || name.starts_with(typed) {
        return Some(Rank(0, 0));
    }
    if let Some(at) = name.windows(typed.len()).position(|window| window == typed) {
        return Some(Rank(1, at));
    }
    let mut wanted = typed.iter();
    let mut next = wanted.next();
    let mut first = None;
    for (position, letter) in name.iter().enumerate() {
        if next == Some(letter) {
            first.get_or_insert(position);
            next = wanted.next();
            if next.is_none() {
                return Some(Rank(2, position - first.unwrap_or(position) + 1 - typed.len()));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn score(typed: &str, name: &str) -> Option<Rank> {
        rank(&normalize(typed.trim()), &normalize(name))
    }

    #[test]
    fn classes_never_overlap_even_for_long_names() {
        let prefix = score("ab", "ab").unwrap();
        let inside = score("ab", &format!("{}ab", "x".repeat(2_000))).unwrap();
        let scattered = score("ab", "axb").unwrap();
        assert!(prefix < inside && inside < scattered);
    }

    #[test]
    fn whitespace_case_unicode_and_order() {
        assert_eq!(score("  ", "orders"), Some(Rank(0, 0)));
        assert_eq!(score(" ÉT ", "Études"), Some(Rank(0, 0)));
        assert_eq!(score("ods", "orders"), Some(Rank(2, 3)));
        assert_eq!(score("sro", "orders"), None);
        assert_eq!(score("longer", "a"), None);
        assert_eq!(score("x", ""), None);
    }

    #[test]
    fn nearer_substrings_and_tighter_subsequences_rank_first() {
        assert!(score("ar", "bar").unwrap() < score("ar", "xxbar").unwrap());
        assert!(score("ab", "axb").unwrap() < score("ab", "axxxb").unwrap());
    }
}
