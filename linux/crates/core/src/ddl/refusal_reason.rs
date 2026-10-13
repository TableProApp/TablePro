use std::fmt;

/// Why one change to one column cannot be made.
///
/// The structure tab shows this beside the control it turns off, so the
/// user learns why before Save rather than from the server afterwards.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RefusalReason {
    /// The engine has no statement for it.
    EngineUnsupported,
    /// A ClickHouse sorting or partition key column, which only a table
    /// rebuild can change.
    KeyColumn,
    /// The server computes the column, and restating it would drop the
    /// expression.
    GeneratedColumn,
    /// The server numbers the column, which rules out a default.
    IdentityColumn,
    /// The column carries an attribute this build does not model, which a
    /// restated definition would drop.
    UnmodeledAttribute(String),
    /// Indexes or foreign keys still use the column.
    ColumnInUse(Vec<String>),
    /// Foreign keys on other tables point at the column or at the primary
    /// key it belongs to.
    ReferencedByForeignKeys(Vec<String>),
    /// The catalogue gave no definition the change could restate.
    UnreadableDefinition,
    /// The column has an attribute the change would break, such as
    /// SPARSE on a SQL Server column made NOT NULL.
    ConflictingAttribute(String),
    /// The restated definition names a column the same change renames.
    /// The server reads it against the new names, and the catalogue's
    /// text still has the old one.
    NamesRenamedColumn(String),
}

impl fmt::Display for RefusalReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EngineUnsupported => f.write_str("the engine cannot make this change"),
            Self::KeyColumn => f.write_str("the column is part of the table's sorting or partition key"),
            Self::GeneratedColumn => f.write_str("the server computes the column"),
            Self::IdentityColumn => f.write_str("the server numbers the column"),
            Self::UnmodeledAttribute(name) => write!(f, "the column has an attribute this app cannot restate: {name}"),
            Self::ColumnInUse(users) => write!(f, "still used by {}", users.join(", ")),
            Self::ReferencedByForeignKeys(keys) => write!(f, "referenced by foreign keys {}", keys.join(", ")),
            Self::UnreadableDefinition => f.write_str("the catalogue gave no definition to restate"),
            Self::ConflictingAttribute(name) => write!(f, "the column's {name} does not allow it"),
            Self::NamesRenamedColumn(name) => write!(f, "its definition names {name}, which the same change renames"),
        }
    }
}
