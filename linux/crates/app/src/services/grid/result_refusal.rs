use tablepro_core::edit::ResultLock;

use crate::i18n::gettext;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResultRefusal {
    NotOneSelect,
    MoreThanOneTable,
    Collapsed,
    Untraced,
    NoPrimaryKey,
    KeyNotShown,
    ColumnsChanged,
    ReadOnlySession,
    OpenTransaction,
    TransactionUnknown,
    OtherDatabase,
    SeveralResults,
    Checking,
    ColumnsUnread,
}

impl From<ResultLock> for ResultRefusal {
    fn from(lock: ResultLock) -> Self {
        match lock {
            ResultLock::NotOneSelect => Self::NotOneSelect,
            ResultLock::MoreThanOneTable => Self::MoreThanOneTable,
            ResultLock::Collapsed => Self::Collapsed,
            ResultLock::Untraced => Self::Untraced,
            ResultLock::NoPrimaryKey => Self::NoPrimaryKey,
            ResultLock::KeyNotShown => Self::KeyNotShown,
            ResultLock::ColumnsChanged => Self::ColumnsChanged,
        }
    }
}

impl ResultRefusal {
    pub fn explanation(self) -> String {
        match self {
            Self::NotOneSelect => gettext("Only the rows of one SELECT can be edited"),
            Self::MoreThanOneTable => gettext("Rows from more than one table, a subquery or a CTE can't be edited"),
            Self::Collapsed => gettext("Grouped, distinct or computed rows can't be edited"),
            Self::Untraced => gettext("Only rows read straight from a table can be edited"),
            Self::NoPrimaryKey => gettext("Rows of a table without a primary key can't be edited"),
            Self::KeyNotShown => {
                gettext("The result leaves out part of the table's primary key, so its rows can't be edited")
            }
            Self::ColumnsChanged => gettext("The table changed since the query ran. Run it again to edit its rows."),
            Self::ReadOnlySession => gettext("This connection is read-only."),
            Self::OpenTransaction => gettext("Rows read inside an open transaction can't be edited here"),
            Self::TransactionUnknown => {
                gettext("The server doesn't say whether a transaction is open, so these rows can't be edited here")
            }
            Self::OtherDatabase => gettext("Rows from another database than the connection's can't be edited here"),
            Self::SeveralResults => gettext("Rows can be edited when the run returns one result"),
            Self::Checking => gettext("Checking whether these rows can be edited…"),
            Self::ColumnsUnread => gettext("The table's columns couldn't be read, so its rows can't be edited"),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn every_refusal_explains_itself_once() {
        let all = [
            ResultRefusal::NotOneSelect,
            ResultRefusal::MoreThanOneTable,
            ResultRefusal::Collapsed,
            ResultRefusal::Untraced,
            ResultRefusal::NoPrimaryKey,
            ResultRefusal::KeyNotShown,
            ResultRefusal::ColumnsChanged,
            ResultRefusal::ReadOnlySession,
            ResultRefusal::OpenTransaction,
            ResultRefusal::TransactionUnknown,
            ResultRefusal::OtherDatabase,
            ResultRefusal::SeveralResults,
            ResultRefusal::Checking,
            ResultRefusal::ColumnsUnread,
        ];

        let texts: HashSet<String> = all.iter().map(|refusal| refusal.explanation()).collect();

        assert_eq!(texts.len(), all.len(), "two refusals share a sentence");
    }
}
