/// The type a grid copy offers its cells as, beside the text: what
/// `CellsEncoder` writes, which a paste prefers to the text.
pub const CELLS_MIME_TYPE: &str = "application/x-tablepro-cells+json";

/// What a copy holds, so an application that reads that type can take it as
/// such: a spreadsheet pastes tab-separated values into cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardFormat {
    PlainText,
    Tsv,
    Csv,
    Json,
    Markdown,
    Sql,
}

impl ClipboardFormat {
    /// The type offered next to plain text, or `None` for text alone.
    pub fn mime_type(self) -> Option<&'static str> {
        match self {
            Self::PlainText => None,
            Self::Tsv => Some("text/tab-separated-values"),
            Self::Csv => Some("text/csv"),
            Self::Json => Some("application/json"),
            Self::Markdown => Some("text/markdown"),
            Self::Sql => Some("application/sql"),
        }
    }
}

/// A rendered copy, ready for the clipboard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardPayload {
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
    pub fn plain(text: String) -> Self {
        Self {
            text,
            format: ClipboardFormat::PlainText,
            rows: 1,
            skipped: 0,
            cells: None,
        }
    }
}

/// The text type is a C string, so a NUL would cut the copy short, and a cut
/// copy pasted back would change the value without a word.
pub fn holds_nul(text: &str) -> bool {
    text.contains('\0')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_format_mime_types() {
        assert_eq!(ClipboardFormat::PlainText.mime_type(), None);
        assert_eq!(ClipboardFormat::Tsv.mime_type(), Some("text/tab-separated-values"));
        assert_eq!(ClipboardFormat::Csv.mime_type(), Some("text/csv"));
        assert_eq!(ClipboardFormat::Json.mime_type(), Some("application/json"));
        assert_eq!(ClipboardFormat::Markdown.mime_type(), Some("text/markdown"));
        assert_eq!(ClipboardFormat::Sql.mime_type(), Some("application/sql"));
    }
}
