use crate::ForeignKeyInfo;

/// One of a table's own foreign keys, with whether its rows can be
/// found by a filter on the table it points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboundForeignKey {
    pub key: ForeignKeyInfo,
    /// Whether `=` on the referenced columns, given this table's values
    /// as text read under the referenced columns' types, finds the rows
    /// the key matches. Columns of different types or collations compare
    /// under a conversion that filter does not make.
    pub parent_compares_alike: bool,
}
