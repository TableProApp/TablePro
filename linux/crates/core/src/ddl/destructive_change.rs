use super::TableRebuild;

/// A part of a structure save that loses data, or drops something the
/// save has to make again, named in the review before it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DestructiveChange {
    /// The rows are copied into a new table and the old one dropped.
    RebuildTable(TableRebuild),
    DropColumn {
        column: String,
    },
    /// The values the column holds are converted, and a value the new
    /// type cannot take is changed or refused.
    ChangeColumnType {
        column: String,
        from: String,
        to: String,
    },
    /// A NULL already in the column has to go: the server refuses the
    /// change, or on some engines puts a default value in its place.
    SetNotNull {
        column: String,
    },
    DropIndex {
        index: String,
    },
    DropForeignKey {
        key: String,
    },
}
