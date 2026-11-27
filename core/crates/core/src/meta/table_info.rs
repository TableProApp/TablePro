/// What the engine keeps about a table beyond its columns: its comment
/// and the space it takes. Each figure is `None` where the engine keeps
/// none or the login may not read it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TableInfo {
    pub comment: Option<String>,
    /// The rows themselves, with the out-of-line pages an engine keeps
    /// apart for long values (PostgreSQL's TOAST, SQL Server's LOB pages).
    pub data_bytes: Option<u64>,
    pub index_bytes: Option<u64>,
    /// Everything the table holds on disk, which can be more than its
    /// data and indexes together.
    pub total_bytes: Option<u64>,
}

impl TableInfo {
    /// A blank comment is no comment.
    pub fn with_comment(mut self, comment: Option<String>) -> Self {
        self.comment = comment.filter(|text| !text.trim().is_empty());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_comment_is_none() {
        assert_eq!(TableInfo::default().with_comment(Some("  ".to_owned())).comment, None);
        assert_eq!(
            TableInfo::default()
                .with_comment(Some("Orders".to_owned()))
                .comment
                .as_deref(),
            Some("Orders")
        );
    }
}
