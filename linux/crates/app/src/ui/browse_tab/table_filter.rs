use tablepro_core::FilterSet;

/// The filter a table tab opens under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TableFilter {
    /// The one last applied to the table, as the sidebar opens it.
    Remembered,
    /// The tab's own, as it was when the tab was saved or closed.
    Kept(FilterSet),
    /// A foreign key's, which the tab opens with its filter strip shown.
    Followed(FilterSet),
}

impl TableFilter {
    /// The set the tab opens under and whether its strip shows it. Only
    /// a tab on the table's remembered filter reads it, so one with its
    /// own leaves the table's alone until the user applies another.
    pub(crate) fn opening(self, remembered: impl FnOnce() -> FilterSet) -> (FilterSet, bool) {
        match self {
            Self::Remembered => (remembered(), false),
            Self::Kept(set) => (set, false),
            Self::Followed(set) => (set, true),
        }
    }
}
