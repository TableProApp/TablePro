use super::PrimaryKeyConstraint;

/// The primary key moving to other columns, or away.
///
/// `to` names the columns as they are after every rename, and is empty
/// when the table is left without a key.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PrimaryKeyChange {
    pub from: Option<PrimaryKeyConstraint>,
    pub to: Vec<String>,
}
