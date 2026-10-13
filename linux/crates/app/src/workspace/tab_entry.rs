use uuid::Uuid;

/// One open tab, as the close prompts name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabEntry {
    pub id: Uuid,
    /// The tab's title without the unsaved-changes bullet.
    pub title: String,
    /// The tab's editor connection holds a transaction the user opened.
    pub open_transaction: bool,
}
