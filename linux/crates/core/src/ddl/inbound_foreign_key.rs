use crate::meta::TableRef;

/// A foreign key on another table that points at this one.
///
/// A rename, a retype or a drop of a referenced column breaks these, so
/// the structure tab lists them before it lets the change through.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct InboundForeignKey {
    pub name: String,
    /// The referencing table.
    pub table: TableRef,
    /// The referencing columns, in key order.
    pub columns: Vec<String>,
    /// The columns of this table they point at, in the same order.
    pub referenced_columns: Vec<String>,
    /// Whether `=` on the referencing columns finds the rows the key
    /// matches. SQLite compares a key under the referenced columns'
    /// affinity and collation, which a referencing column can declare
    /// otherwise; the other engines make the two sides agree.
    pub child_compares_alike: bool,
}
