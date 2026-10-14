use super::ShortcutSection;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShortcutListing {
    Listed(ShortcutSection),
    Unlisted,
}
