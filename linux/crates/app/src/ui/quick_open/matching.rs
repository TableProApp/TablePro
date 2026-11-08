/// How well `name` answers what the user typed, lower the better, or
/// `None` when it does not. A name that starts with the text comes first,
/// then one that holds it, then one whose letters follow it in order with
/// others between, as a fuzzy finder takes them.
pub(super) fn rank(typed: &str, name: &str) -> Option<u32> {
    let typed: Vec<char> = typed.trim().chars().flat_map(char::to_lowercase).collect();
    if typed.is_empty() {
        return Some(0);
    }
    let name: Vec<char> = name.chars().flat_map(char::to_lowercase).collect();
    if name.starts_with(&typed) {
        return Some(0);
    }
    if let Some(at) = name.windows(typed.len()).position(|window| window == typed.as_slice()) {
        return Some(100 + u32::try_from(at).unwrap_or(u32::MAX - 100));
    }
    // The letters in order, charged for each one skipped between them.
    let mut wanted = typed.iter().peekable();
    let mut skipped = 0u32;
    let mut started = false;
    for letter in &name {
        match wanted.peek() {
            Some(next) if *next == letter => {
                wanted.next();
                started = true;
            }
            Some(_) if started => skipped = skipped.saturating_add(1),
            _ => {}
        }
    }
    wanted.peek().is_none().then_some(1_000 + skipped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_search_keeps_everything() {
        assert_eq!(rank("  ", "orders"), Some(0));
    }

    #[test]
    fn a_prefix_beats_a_hit_inside_beats_scattered_letters() {
        let prefix = rank("ord", "orders").expect("a prefix");
        let inside = rank("der", "orders").expect("inside");
        let scattered = rank("ods", "orders").expect("scattered");

        assert!(prefix < inside && inside < scattered, "{prefix} {inside} {scattered}");
    }

    #[test]
    fn case_does_not_matter_and_a_miss_is_none() {
        assert_eq!(rank("ORD", "Orders"), Some(0));
        assert_eq!(rank("xyz", "orders"), None);
        assert_eq!(rank("sro", "orders"), None, "the letters were out of order");
    }

    #[test]
    fn a_nearer_hit_inside_ranks_first() {
        assert!(rank("ar", "bar").expect("near") < rank("ar", "xxbar").expect("far"));
    }
}
