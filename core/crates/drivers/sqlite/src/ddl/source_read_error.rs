use std::fmt;

/// Why the CREATE TABLE text SQLite stored could not be read as the
/// table the catalogue describes. A rebuild splices that text, so any
/// doubt about it refuses the changes only a rebuild makes. It never
/// leaves the crate: the plan turns it into `UnreadableDefinition`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SourceReadError {
    Missing,
    /// A virtual table, or a statement that is not CREATE TABLE.
    NotCreateTable,
    Unexpected {
        offset: usize,
        found: String,
    },
    Unterminated,
    TableName {
        expected: String,
        found: String,
    },
    ColumnCount {
        expected: usize,
        found: usize,
    },
    ColumnName {
        position: usize,
        expected: String,
        found: String,
    },
    ForeignKeyCount {
        expected: usize,
        found: usize,
    },
}

impl fmt::Display for SourceReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing => f.write_str("the catalogue gave no CREATE statement"),
            Self::NotCreateTable => f.write_str("not a CREATE TABLE statement with a column list"),
            Self::Unexpected { offset, found } => write!(f, "unexpected {found:?} at byte {offset}"),
            Self::Unterminated => f.write_str("the statement ends before its column list closes"),
            Self::TableName { expected, found } => write!(f, "the statement creates {found}, not {expected}"),
            Self::ColumnCount { expected, found } => write!(
                f,
                "the statement declares {found} columns where the catalogue has {expected}"
            ),
            Self::ColumnName {
                position,
                expected,
                found,
            } => write!(
                f,
                "column {position} is {found} in the statement and {expected} in the catalogue"
            ),
            Self::ForeignKeyCount { expected, found } => write!(
                f,
                "the statement declares {found} foreign keys where the catalogue has {expected}"
            ),
        }
    }
}

impl std::error::Error for SourceReadError {}
