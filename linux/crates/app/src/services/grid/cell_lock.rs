use tablepro_core::edit::{EditParseError, ReadOnlyReason};

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
    ReadOnlySession,
    /// The row is marked for deletion.
    PendingDelete,
    /// An update cannot name the column (ADR 0026).
    Unaddressable,
    /// The running save writes this cell. An editor left open across the
    /// save would commit against the value read before it.
    Saving,
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
            Self::ReadOnlySession => gettext("This connection is read-only."),
            Self::PendingDelete => gettext("Rows marked for deletion can't be edited"),
            Self::Unaddressable => {
                gettext("A field whose name has a dot or starts with $ can only be changed in the editor")
            }
            Self::Saving => gettext("This row is being saved. Change it again once the save finishes."),
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
            CellLock::ReadOnlySession,
            CellLock::PendingDelete,
            CellLock::Unaddressable,
            CellLock::Saving,
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
