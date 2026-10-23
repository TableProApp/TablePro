/// The type a grid copy offers its cells as, beside the text: what
/// `CellsEncoder` writes, which a paste prefers to the text.
pub(crate) const CELLS_MIME_TYPE: &str = "application/x-tablepro-cells+json";

/// What a copy holds, so an application that reads that type can take
/// it as such: a spreadsheet pastes tab-separated values into cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ClipboardFormat {
    PlainText,
    Tsv,
    Csv,
    Json,
    Markdown,
    Sql,
}

impl ClipboardFormat {
    /// The type offered next to plain text, or `None` for text alone.
    pub(crate) fn mime_type(self) -> Option<&'static str> {
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
