use super::ColumnType;

/// A column of a result set, which is all a driver can say about an
/// arbitrary query's output.
///
/// Browse uses `ColumnInfo` from `fetch_columns`, which knows about
/// keys and defaults. A result column knows only its name and type,
/// because that is all a `SELECT` over an expression has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResultColumn {
    pub name: String,
    pub column_type: ColumnType,
}

impl ResultColumn {
    pub fn new(name: impl Into<String>, column_type: ColumnType) -> Self {
        Self {
            name: name.into(),
            column_type,
        }
    }
}
