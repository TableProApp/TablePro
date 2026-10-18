/// The name a copy of `base` gets: "Prod (Copy)", then "Prod (Copy 2)"
/// with the smallest number nobody holds, as GNOME Files names copies.
/// A copy of a copy counts on from the original rather than stacking a
/// second suffix.
pub(crate) fn duplicate_name(base: &str, existing: &[String]) -> String {
    let original = original_name(base);
    let taken = |candidate: &String| existing.iter().any(|name| name == candidate);
    let first = copy_name(original);
    if !taken(&first) {
        return first;
    }
    // The list is a person's own connections, so the count ends within
    // as many steps as they have copies.
    (2_u64..)
        .map(|n| numbered_copy_name(original, &n.to_string()))
        .find(|candidate| !taken(candidate))
        .unwrap_or(first)
}

fn copy_name(name: &str) -> String {
    crate::i18n::gettext_f("{name} (Copy)", &[("name", name)])
}

fn numbered_copy_name(name: &str, n: &str) -> String {
    crate::i18n::gettext_f("{name} (Copy {n})", &[("name", name), ("n", n)])
}

/// Stands in for the name and the number while the translated patterns
/// are taken apart. Neither can be typed into a name.
const NAME: &str = "\u{0}";
const NUMBER: &str = "\u{1}";

/// `name` without the copy suffix it ends in, in the user's language.
fn original_name(name: &str) -> &str {
    let plain = copy_name(NAME);
    if let Some((before, after)) = plain.split_once(NAME)
        && let Some(original) = name.strip_prefix(before).and_then(|rest| rest.strip_suffix(after))
        && !original.is_empty()
    {
        return original;
    }
    let numbered = numbered_copy_name(NAME, NUMBER);
    let Some((before, rest)) = numbered.split_once(NAME) else {
        return name;
    };
    // A translation that puts the number ahead of the name is left as
    // it is: the copy then reads "(Copy) (Copy)", which is still clear.
    let Some((between, after)) = rest.split_once(NUMBER) else {
        return name;
    };
    let Some(inner) = name.strip_prefix(before).and_then(|rest| rest.strip_suffix(after)) else {
        return name;
    };
    match inner.rsplit_once(between) {
        Some((original, n)) if !original.is_empty() && n.parse::<u64>().is_ok_and(|n| n >= 2) => original,
        _ => name,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn duplicate_name_appends_copy_then_counter() {
        let mut existing = names(&["Prod"]);
        for expected in ["Prod (Copy)", "Prod (Copy 2)", "Prod (Copy 3)"] {
            let name = duplicate_name("Prod", &existing);
            assert_eq!(name, expected);
            existing.push(name);
        }
    }

    #[test]
    fn the_smallest_free_number_is_taken() {
        let existing = names(&["db", "db (Copy)", "db (Copy 3)"]);

        assert_eq!(duplicate_name("db", &existing), "db (Copy 2)");
    }

    #[test]
    fn a_copy_of_a_copy_counts_on_from_the_original() {
        let existing = names(&["Prod", "Prod (Copy)", "Prod (Copy 2)"]);

        assert_eq!(duplicate_name("Prod (Copy)", &existing), "Prod (Copy 3)");
        assert_eq!(duplicate_name("Prod (Copy 2)", &existing), "Prod (Copy 3)");
    }

    #[test]
    fn a_name_that_only_looks_numbered_keeps_its_text() {
        let existing = names(&["Release (Copy 1)", "(Copy)"]);

        assert_eq!(duplicate_name("Release (Copy 1)", &existing), "Release (Copy 1) (Copy)");
        assert_eq!(duplicate_name("(Copy)", &existing), "(Copy) (Copy)");
    }
}
