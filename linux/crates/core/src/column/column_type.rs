use super::{CatalogType, ColumnKind, ReadForm};

/// A column's type: what the app needs to render and edit it, plus the
/// server's own spelling for splicing it into DDL and casts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnType {
    /// What the user sees. Never spliced into SQL: that is what
    /// `catalog` is for.
    pub name: String,
    pub kind: ColumnKind,
    /// `None` where the driver has no server spelling to quote, as for
    /// most result-set columns. A dialect then refuses to guess a cast.
    pub catalog: Option<CatalogType>,
    /// Whether the server decides the stored width per row, so a
    /// declared length is a cap rather than a promise.
    pub dynamic_storage: bool,
    pub read_form: ReadForm,
}

impl ColumnType {
    /// A stand-in for a column whose type is not known yet, used
    /// while the catalogue is still loading.
    ///
    /// It has no catalogue entry, so nothing can splice it into DDL or
    /// a cast: a caller that needs the server's own spelling has to
    /// wait for the catalogue rather than invent one.
    pub fn unknown() -> Self {
        Self::untyped_text(String::new())
    }

    /// The fallback for a type no driver placed: the value is the
    /// server's text and the grid treats it as such.
    pub fn untyped_text(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ColumnKind::Other,
            catalog: None,
            dynamic_storage: true,
            read_form: ReadForm::ServerText,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_type_names_nothing_the_server_would_recognise() {
        let unknown = ColumnType::unknown();

        assert_eq!(unknown.name, "");
        assert_eq!(unknown.kind, ColumnKind::Other);
        assert_eq!(unknown.catalog, None);
    }

    #[test]
    fn untyped_text_reads_as_server_text() {
        let column = ColumnType::untyped_text("geography");

        assert_eq!(column.kind, ColumnKind::Other);
        assert_eq!(column.read_form, ReadForm::ServerText);
        assert_eq!(column.catalog, None);
        assert!(column.dynamic_storage);
        assert_eq!(column.name, "geography");
    }
}
