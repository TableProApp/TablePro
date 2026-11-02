/// A table's own default character set and collation and its next
/// AUTO_INCREMENT value, on an engine whose tables carry them.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TableOptions {
    pub character_set: Option<String>,
    pub collation: Option<String>,
    /// The number the next inserted row takes, `None` when no column of
    /// the table numbers itself.
    pub next_auto_increment: Option<u64>,
}
