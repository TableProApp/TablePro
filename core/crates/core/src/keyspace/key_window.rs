use std::num::NonZeroU32;

/// Where a key's next window starts, in the engine's own terms: a scan
/// cursor, a list index, a stream entry id. Only the driver that gave it
/// out reads it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyCursor(String);

impl KeyCursor {
    pub fn start() -> Self {
        Self(String::new())
    }

    pub fn new(position: impl Into<String>) -> Self {
        Self(position.into())
    }

    pub fn is_start(&self) -> bool {
        self.0.is_empty()
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// One read of a key's value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyWindow {
    pub cursor: KeyCursor,
    /// At most this many entries: fields, members, elements or stream
    /// entries. A scan cursor can return a few more, as the engine's own
    /// `COUNT` is a hint.
    pub limit: NonZeroU32,
}

impl KeyWindow {
    /// What the key tab reads at a time.
    pub const PAGE: NonZeroU32 = NonZeroU32::new(500).expect("500 is not zero");

    pub fn first() -> Self {
        Self {
            cursor: KeyCursor::start(),
            limit: Self::PAGE,
        }
    }

    pub fn after(cursor: KeyCursor) -> Self {
        Self {
            cursor,
            limit: Self::PAGE,
        }
    }
}
