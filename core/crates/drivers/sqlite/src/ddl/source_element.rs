use std::ops::Range;

use super::column_constraint_segment::ColumnConstraintSegment;

/// One entry of the CREATE TABLE list: a column or a table constraint,
/// from its first token to its last.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SourceElement {
    pub range: Range<usize>,
    pub kind: ElementKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ElementKind {
    Column(SourceColumn),
    Constraint(TableConstraint),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SourceColumn {
    /// As SQLite reads it, quotes removed.
    pub name: String,
    pub name_range: Range<usize>,
    /// `None` for a column declared without a type.
    pub type_range: Option<Range<usize>>,
    pub segments: Vec<ColumnConstraintSegment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TableConstraint {
    pub name: Option<String>,
    pub kind: TableConstraintKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TableConstraintKind {
    PrimaryKey {
        columns: Vec<String>,
        autoincrement: bool,
    },
    Unique {
        columns: Vec<String>,
    },
    Check,
    ForeignKey {
        columns: Vec<String>,
        target: ForeignKeyTarget,
    },
    /// `CONSTRAINT name` with nothing after it, which SQLite accepts.
    NameOnly,
}

/// What a foreign key points at. No columns means the parent's primary
/// key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForeignKeyTarget {
    pub table: String,
    pub columns: Vec<String>,
}

/// A foreign key the text declares, inline on a column or as a table
/// constraint, in the order SQLite numbers them from the end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SourceForeignKey<'s> {
    /// The name its CONSTRAINT clause gives it.
    pub name: Option<&'s str>,
    pub element: usize,
    /// The REFERENCES segment of an inline key.
    pub segment: Option<usize>,
    pub columns: &'s [String],
    pub target: &'s ForeignKeyTarget,
}
