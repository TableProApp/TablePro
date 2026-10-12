use std::ops::Range;

/// Where the visible columns and the row's identity sit in what a page
/// query returns.
///
/// The identity columns come straight after the visible ones. Its range
/// is empty when the key is made of visible columns, and holds the
/// hidden engine row id parts otherwise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageLayout {
    pub visible: Range<usize>,
    pub identity: Range<usize>,
}

impl PageLayout {
    pub(super) fn new(visible: usize, hidden: usize) -> Self {
        Self {
            visible: 0..visible,
            identity: visible..visible + hidden,
        }
    }

    /// How many columns the query returns.
    pub fn width(&self) -> usize {
        self.identity.end
    }
}
