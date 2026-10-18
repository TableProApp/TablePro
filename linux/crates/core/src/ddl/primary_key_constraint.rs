/// A table's primary key as a constraint, with its name.
///
/// The name matters for DDL that drops or restates the key. It is
/// `None` on engines that do not name it, such as SQLite.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PrimaryKeyConstraint {
    pub name: Option<String>,
    pub columns: Vec<String>,
}
