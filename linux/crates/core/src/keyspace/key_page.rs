use std::time::Duration;

use super::KeyCursor;
use crate::meta::KeyKind;
use crate::query_result::QueryResult;

/// How long a key has left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyTtl {
    Persistent,
    ExpiresIn(Duration),
}

/// One window of a key's value, with what the key is.
#[derive(Debug, Clone)]
pub struct KeyPage {
    pub kind: KeyKind,
    /// The engine's own name for the type, which is what the tab shows
    /// for a type it does not read.
    pub type_name: String,
    pub ttl: KeyTtl,
    /// The number of entries, or the bytes of a string.
    pub length: Option<u64>,
    /// The window's entries, in the columns the type has: a string's
    /// value, a hash's field and value, a list's index and element, a
    /// set's member, a sorted set's member and score, a stream's entry id
    /// and fields. `truncated` says a string was cut at the window's
    /// byte limit.
    pub rows: QueryResult,
    /// Where the next window starts, or `None` at the end.
    pub next: Option<KeyCursor>,
}
