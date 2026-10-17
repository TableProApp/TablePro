use futures::future::LocalBoxFuture;
use uuid::Uuid;

use super::TabEntry;

/// What the workspace needs from the window's tabs that no tracker
/// holds: their order, their names, their open transactions and the
/// files their text is saved to.
pub trait TabDirectory {
    /// Every open tab, in the order the tab bar shows them.
    fn tabs(&self) -> Vec<TabEntry>;

    /// Write `tab`'s text to its file, or `None` when it has none. The
    /// error is the sentence to show.
    fn save_file(&self, _tab: Uuid) -> Option<LocalBoxFuture<'static, Result<(), String>>> {
        None
    }
}
