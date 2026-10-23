use std::time::Duration;

use tablepro_core::keyspace::KeyTtl;
use tablepro_core::meta::KeyKind;

use crate::i18n::{ngettext_f, pgettext};
use crate::ui::format::{format_thousands, plural_count};

/// The type of value a key holds, in Redis's documentation's words.
pub(crate) fn key_kind_name(kind: KeyKind) -> String {
    match kind {
        KeyKind::String => pgettext("key type", "String"),
        KeyKind::Hash => pgettext("key type", "Hash"),
        KeyKind::List => pgettext("key type", "List"),
        KeyKind::Set => pgettext("key type", "Set"),
        KeyKind::SortedSet => pgettext("key type", "Sorted Set"),
        KeyKind::Stream => pgettext("key type", "Stream"),
        KeyKind::Other => pgettext("key type", "Other"),
    }
}

/// How many entries the key holds, in the words its type uses: a
/// string's bytes, a hash's fields, a list's elements.
pub(super) fn length_text(kind: KeyKind, length: u64) -> Option<String> {
    let count = plural_count(length);
    let n = format_thousands(length);
    let placeholders = [("n", n.as_str())];
    Some(match kind {
        KeyKind::String => ngettext_f("{n} byte", "{n} bytes", count, &placeholders),
        KeyKind::Hash => ngettext_f("{n} field", "{n} fields", count, &placeholders),
        KeyKind::List => ngettext_f("{n} element", "{n} elements", count, &placeholders),
        KeyKind::Set | KeyKind::SortedSet => ngettext_f("{n} member", "{n} members", count, &placeholders),
        KeyKind::Stream => ngettext_f("{n} entry", "{n} entries", count, &placeholders),
        KeyKind::Other => return None,
    })
}

/// When the key expires, in the largest whole unit that fits, or
/// nothing when the server would not say.
pub(super) fn ttl_text(ttl: KeyTtl) -> Option<String> {
    let left = match ttl {
        KeyTtl::Persistent => return Some(pgettext("key expiry", "No expiry")),
        KeyTtl::Unknown => return None,
        KeyTtl::ExpiresIn(left) => left,
    };
    let (count, unit) = largest_unit(left);
    let n = count.to_string();
    let placeholders = [("n", n.as_str())];
    let count = plural_count(count);
    Some(match unit {
        Unit::Seconds => ngettext_f("Expires in {n} second", "Expires in {n} seconds", count, &placeholders),
        Unit::Minutes => ngettext_f("Expires in {n} minute", "Expires in {n} minutes", count, &placeholders),
        Unit::Hours => ngettext_f("Expires in {n} hour", "Expires in {n} hours", count, &placeholders),
        Unit::Days => ngettext_f("Expires in {n} day", "Expires in {n} days", count, &placeholders),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Unit {
    Seconds,
    Minutes,
    Hours,
    Days,
}

/// A key with a few milliseconds left still has under a second, which
/// reads as one rather than none.
fn largest_unit(left: Duration) -> (u64, Unit) {
    let seconds = left.as_secs().max(1);
    match seconds {
        0..60 => (seconds, Unit::Seconds),
        60..3_600 => (seconds / 60, Unit::Minutes),
        3_600..172_800 => (seconds / 3_600, Unit::Hours),
        _ => (seconds / 86_400, Unit::Days),
    }
}

/// How many of the key's entries the tab holds, of how many.
pub(super) fn shown_text(shown: u64, length: Option<u64>) -> String {
    match length {
        Some(length) if length > shown => ngettext_f(
            "{shown} of {n} shown",
            "{shown} of {n} shown",
            plural_count(length),
            &[("shown", &format_thousands(shown)), ("n", &format_thousands(length))],
        ),
        _ => ngettext_f(
            "{n} shown",
            "{n} shown",
            plural_count(shown),
            &[("n", &format_thousands(shown))],
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_type_counts_in_its_own_words() {
        assert_eq!(length_text(KeyKind::Hash, 1).as_deref(), Some("1 field"));
        assert_eq!(length_text(KeyKind::List, 3).as_deref(), Some("3 elements"));
        assert_eq!(length_text(KeyKind::SortedSet, 2).as_deref(), Some("2 members"));
        assert_eq!(length_text(KeyKind::String, 5).as_deref(), Some("5 bytes"));
        assert_eq!(length_text(KeyKind::Stream, 1).as_deref(), Some("1 entry"));
        assert_eq!(length_text(KeyKind::Other, 1), None);
    }

    #[test]
    fn an_expiry_reads_in_the_largest_unit_that_fits() {
        let text = |ttl| ttl_text(ttl).unwrap_or_default();
        assert_eq!(text(KeyTtl::Persistent), "No expiry");
        assert_eq!(text(KeyTtl::ExpiresIn(Duration::from_millis(300))), "Expires in 1 second");
        assert_eq!(text(KeyTtl::ExpiresIn(Duration::from_secs(59))), "Expires in 59 seconds");
        assert_eq!(text(KeyTtl::ExpiresIn(Duration::from_secs(150))), "Expires in 2 minutes");
        assert_eq!(text(KeyTtl::ExpiresIn(Duration::from_secs(7_200))), "Expires in 2 hours");
        assert_eq!(text(KeyTtl::ExpiresIn(Duration::from_secs(259_200))), "Expires in 3 days");
        assert_eq!(ttl_text(KeyTtl::Unknown), None);
    }

    #[test]
    fn the_footer_says_how_much_is_shown() {
        assert_eq!(shown_text(500, Some(1_234)), "500 of 1,234 shown");
        assert_eq!(shown_text(3, Some(3)), "3 shown");
        assert_eq!(shown_text(1, None), "1 shown");
    }
}
