use super::TabEntry;

/// What the workspace needs from the window's tabs that no tracker
/// holds: their order, their names and their open transactions.
pub trait TabDirectory {
    /// Every open tab, in the order the tab bar shows them.
    fn tabs(&self) -> Vec<TabEntry>;
}
