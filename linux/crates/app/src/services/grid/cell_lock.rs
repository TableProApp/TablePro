use tablepro_core::edit::{EditParseError, ReadOnlyReason};

use super::ResultRefusal;
use crate::i18n::gettext;

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
    Result(ResultRefusal),
    // An expression, or a second copy of a column the result already writes.
    NotTableColumn,
    ReadOnlySession,
    /// The row is marked for deletion.
    PendingDelete,
    /// An update cannot name the column (ADR 0026).
    Unaddressable,
    /// The running save writes this cell. An editor left open across the
    /// save would commit against the value read before it.
    Saving,
    // The connection's masking rules hide this column's values, which the grid no longer holds.
    Masked,
    // A key column is masked, so no row can be named to the server.
    MaskedKey,
}

impl CellLock {
    /// Why the cell takes no value. `Value` is worded by the UI's
    /// `edit_parse_message`, passed in, so the sentence keeps one home.
    pub fn explanation(self, parse_message: impl Fn(&EditParseError) -> String) -> String {
        match self {
            Self::Value(reason) => parse_message(&EditParseError::NotEditable(reason)),
            Self::KeyColumn => gettext("A saved row's key can't be changed here"),
            Self::Generated => gettext("The database computes this column's values"),
            Self::AutoIncrement => gettext("The database numbers this column's values"),
            Self::UnkeyedRow => gettext("Rows of a table without a primary key can't be edited"),
            Self::ResultRow => gettext("Query results can't be edited here"),
            Self::Result(refusal) => refusal.explanation(),
            Self::NotTableColumn => gettext("This column can't be written back to the table"),
            Self::ReadOnlySession => gettext("This connection is read-only."),
            Self::PendingDelete => gettext("Rows marked for deletion can't be edited"),
            Self::Unaddressable => {
                gettext("A field whose name has a dot or starts with $ can only be changed in the editor")
            }
            Self::Saving => gettext("This row is being saved. Change it again once the save finishes."),
            Self::Masked => gettext("This column is masked, so its values can't be edited here"),
            Self::MaskedKey => gettext("The table's key is masked, so its rows can't be edited here"),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use tablepro_core::edit::{EditParseError, ReadOnlyReason};

    use super::CellLock;

    #[test]
    fn every_lock_explains_itself_and_a_value_lock_asks_the_ui() {
        let locks = [
            CellLock::KeyColumn,
            CellLock::Generated,
            CellLock::AutoIncrement,
            CellLock::UnkeyedRow,
            CellLock::ResultRow,
            CellLock::NotTableColumn,
            CellLock::ReadOnlySession,
            CellLock::PendingDelete,
            CellLock::Unaddressable,
            CellLock::Saving,
            CellLock::Masked,
            CellLock::MaskedKey,
        ];
        let unused = |_: &EditParseError| String::new();

        let texts: HashSet<String> = locks.iter().map(|lock| lock.explanation(unused)).collect();

        assert_eq!(texts.len(), locks.len(), "two locks share a sentence");
        assert!(texts.iter().all(|text| !text.is_empty()));
        assert_eq!(
            CellLock::Value(ReadOnlyReason::Bytes).explanation(|error| format!("{error:?}")),
            "NotEditable(Bytes)"
        );
    }
}
