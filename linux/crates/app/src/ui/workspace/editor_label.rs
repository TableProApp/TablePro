/// What an editor tab is named after.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum EditorLabel {
    /// No text to name it by: the tab's number among the editor tabs.
    Untitled(usize),
    /// The start of its script, at most the 200 characters the tab
    /// reads, and whether the script goes on past it.
    Query { prefix: String, truncated: bool },
}

impl EditorLabel {
    /// A blank script is named by `ordinal`, so a label is never empty.
    pub(crate) fn of(ordinal: usize, prefix: &str, truncated: bool) -> Self {
        if !truncated && prefix.trim().is_empty() {
            Self::Untitled(ordinal)
        } else {
            Self::Query {
                prefix: prefix.to_owned(),
                truncated,
            }
        }
    }
}
