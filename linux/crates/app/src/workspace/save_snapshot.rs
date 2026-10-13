use crate::services::touch::Touch;

/// Where a save's edits end: every edit touched before this one is in
/// the save, and an edit touched at or after it was made while the save
/// ran, so a commit leaves it pending.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SaveSnapshot(pub Touch);

impl SaveSnapshot {
    pub fn includes(self, touched: Touch) -> bool {
        touched < self.0
    }
}
