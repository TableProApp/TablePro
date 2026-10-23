use tablepro_core::edit::ReadOnlyReason;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellLock {
    /// The column's values have no text form to type.
    Value(ReadOnlyReason),
    /// The row is named by this column, so changing it in place would
    /// lose the row it names.
    KeyColumn,
    Generated,
    AutoIncrement,
    UnkeyedRow,
    ResultRow,
    ReadOnlySession,
}

impl CellLock {
    /// Why the cell takes no value, for an edit that cannot open an
    /// editor to show it, such as a paste.
    pub fn explanation(self) -> String {
        match self {
            Self::Value(reason) => {
                crate::ui::error_text::edit_parse_message(&tablepro_core::edit::EditParseError::NotEditable(reason))
            }
            Self::KeyColumn => crate::i18n::gettext("A saved row's key can't be changed here"),
            Self::Generated => crate::i18n::gettext("The database computes this column's values"),
            Self::AutoIncrement => crate::i18n::gettext("The database numbers this column's values"),
            Self::UnkeyedRow => crate::i18n::gettext("Rows of a table without a primary key can't be edited"),
            Self::ResultRow => crate::i18n::gettext("Query results can't be edited here"),
            Self::ReadOnlySession => crate::i18n::gettext("This connection is read-only."),
        }
    }
}
