/// When a pending change was made, from a counter its tracker owns. A
/// save runs its rows in touch order, so the statements follow the
/// edits rather than the order a hash map happens to iterate in.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Touch(u64);

impl Touch {
    #[must_use]
    pub fn next(self) -> Self {
        Touch(self.0 + 1)
    }
}
