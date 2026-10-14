use uuid::Uuid;

/// One open tab, as the close prompts name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabEntry {
    pub id: Uuid,
    /// The title its tab shows.
    pub title: String,
    /// The tab's editor connection holds a transaction the user opened.
    pub open_transaction: bool,
}
