use super::draft_column_object::DraftColumnObject;

/// What changes the draft's columns.
#[derive(Debug)]
pub(crate) enum ColumnsInput {
    ColumnEdited {
        column: DraftColumnObject,
        field: ColumnField,
    },
    AddColumn,
    RemoveColumn(DraftColumnObject),
}

#[derive(Debug, Clone)]
pub enum ColumnField {
    Name(String),
    Type(String),
    Nullable(bool),
    PrimaryKey(bool),
    AutoIncrement(bool),
    /// SQL text; empty is no default.
    Default(String),
    Comment(Option<String>),
    /// A character set and the collation that goes with it, written
    /// together. `None` takes the table's.
    CharacterSet {
        character_set: Option<String>,
        collation: Option<String>,
    },
    Collation(Option<String>),
}
