use crate::column::SqlExpression;

/// Whether a generated column's value is kept on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum GeneratedStorage {
    Virtual,
    /// Computed on write and stored. MariaDB's `PERSISTENT` is this.
    Stored,
}

/// A column the server computes from an expression.
///
/// The expression is kept because a redefinition that drops it turns
/// the column into a plain one and loses every computed value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GeneratedColumn {
    pub expression: SqlExpression,
    pub storage: GeneratedStorage,
}
