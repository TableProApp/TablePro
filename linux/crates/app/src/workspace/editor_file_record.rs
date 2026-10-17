use serde::{Deserialize, Serialize};

/// The `.sql` file an editor tab is saved to, kept with the tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorFileRecord {
    /// A URI rather than a path, so a file the document portal handed
    /// over reads back the same way as a local one.
    pub uri: String,
    /// The tab's text, which its draft keeps, differs from the file's.
    pub modified: bool,
}
