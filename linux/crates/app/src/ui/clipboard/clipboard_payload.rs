use super::ClipboardFormat;

/// A rendered copy, ready for the clipboard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ClipboardPayload {
    pub text: String,
    pub format: ClipboardFormat,
    /// The rows it holds, or the values for an IN list.
    pub rows: usize,
    /// Values an IN list had to leave out.
    pub skipped: usize,
    /// The copied cells as `CellsEncoder` writes them, offered beside the
    /// text so a paste reads them back exactly.
    pub cells: Option<String>,
}

impl ClipboardPayload {
    pub(crate) fn plain(text: String) -> Self {
        Self {
            text,
            format: ClipboardFormat::PlainText,
            rows: 1,
            skipped: 0,
            cells: None,
        }
    }
}
