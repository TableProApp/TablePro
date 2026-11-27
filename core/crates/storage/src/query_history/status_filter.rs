/// Which outcomes a history search keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum StatusFilter {
    #[default]
    Any,
    Succeeded,
    Failed,
    Cancelled,
    // Every run that did not succeed, cancelled ones included, as the macOS History pane's Failed reads.
    Unsuccessful,
}

impl StatusFilter {
    /// A cancelled run is stored with `success = 0`, so Failed has to
    /// leave it out explicitly.
    pub(super) fn predicate(self) -> Option<&'static str> {
        match self {
            Self::Any => None,
            Self::Succeeded => Some("h.success = 1 AND h.cancelled = 0"),
            Self::Failed => Some("h.success = 0 AND h.cancelled = 0"),
            Self::Cancelled => Some("h.cancelled = 1"),
            Self::Unsuccessful => Some("h.success = 0"),
        }
    }
}
