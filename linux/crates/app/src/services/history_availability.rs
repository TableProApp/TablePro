/// Whether the query history is usable yet.
///
/// The database opens in the background, so the menu item that needs it
/// stays disabled until it is `Ready` instead of opening a dialog that
/// cannot search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryAvailability {
    Starting,
    Ready,
    Failed(String),
}

impl HistoryAvailability {
    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready)
    }

    pub fn failure(&self) -> Option<&str> {
        match self {
            Self::Failed(detail) => Some(detail),
            _ => None,
        }
    }
}
