use std::ops::Range;

use super::source_element::ForeignKeyTarget;

/// One column constraint as the CREATE TABLE text spells it, with the
/// bytes it takes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ColumnConstraintSegment {
    pub range: Range<usize>,
    pub kind: ColumnConstraintKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ColumnConstraintKind {
    /// `CONSTRAINT name`, which SQLite reads as its own entry naming the
    /// constraint after it.
    Name(String),
    PrimaryKey {
        autoincrement: bool,
    },
    NotNull,
    Null,
    Unique,
    Check,
    Default,
    Collate,
    References(ForeignKeyTarget),
    Generated,
    /// `[NOT] DEFERRABLE ...` standing on its own, which SQLite applies
    /// to the foreign key before it.
    Deferrable,
}
