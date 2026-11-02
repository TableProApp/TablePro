use std::num::NonZeroUsize;

use crate::meta::ObjectInfo;

/// Which keys to list.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyScan {
    /// The engine's own glob, such as `user:*`, matched on the server.
    /// `None` lists every key.
    pub pattern: Option<String>,
    /// How many keys the listing may hold. A database can hold millions,
    /// and the sidebar shows a prefix and says so.
    pub limit: NonZeroUsize,
}

impl KeyScan {
    /// What the sidebar lists.
    pub const SIDEBAR_LIMIT: NonZeroUsize = NonZeroUsize::new(5_000).expect("5,000 is not zero");

    pub fn sidebar(pattern: Option<String>) -> Self {
        Self {
            pattern: pattern.filter(|pattern| !pattern.is_empty()),
            limit: Self::SIDEBAR_LIMIT,
        }
    }

    /// The pattern for what a user typed into a search: text with a `*`,
    /// `?` or `[` is a glob as it is, and any other text matches keys
    /// that hold it anywhere, as the table search does. Blank text lists
    /// every key.
    pub fn search(typed: &str) -> Option<String> {
        let typed = typed.trim();
        if typed.is_empty() {
            return None;
        }
        if typed.contains(['*', '?', '[']) {
            return Some(typed.to_owned());
        }
        Some(format!("*{}*", glob_escape(typed)))
    }
}

/// `text` matched as it is in a glob: its wildcards and the escape
/// itself are escaped with a backslash.
pub fn glob_escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(c, '*' | '?' | '[' | ']' | '\\') {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

/// The keys a scan found, each an `ObjectInfo` of kind `Key`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct KeyListing {
    pub keys: Vec<ObjectInfo>,
    /// Whether every matching key is listed. A scan stops early at its
    /// limit, or when walking a large database for a rare pattern takes
    /// longer than the call may.
    pub complete: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_pattern_lists_every_key() {
        assert_eq!(KeyScan::sidebar(Some(String::new())).pattern, None);
        assert_eq!(
            KeyScan::sidebar(Some("user:*".to_owned())).pattern.as_deref(),
            Some("user:*")
        );
        assert_eq!(KeyScan::sidebar(None).limit.get(), 5_000);
    }

    #[test]
    fn typed_text_matches_anywhere_and_a_glob_is_taken_as_it_is() {
        assert_eq!(KeyScan::search("  "), None);
        assert_eq!(KeyScan::search("user").as_deref(), Some("*user*"));
        assert_eq!(KeyScan::search(r"a\b]").as_deref(), Some(r"*a\\b\]*"));
        assert_eq!(KeyScan::search("user:*").as_deref(), Some("user:*"));
        assert_eq!(KeyScan::search("h?llo").as_deref(), Some("h?llo"));
    }
}
