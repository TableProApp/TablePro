use super::{ColumnOrigin, ColumnType};

// Browse reads keys and defaults from `ColumnInfo`; an arbitrary query's output has only a name, a type and maybe an origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResultColumn {
    pub name: String,
    pub column_type: ColumnType,
    pub origin: Option<ColumnOrigin>,
}

impl ResultColumn {
    pub fn new(name: impl Into<String>, column_type: ColumnType) -> Self {
        Self {
            name: name.into(),
            column_type,
            origin: None,
        }
    }

    pub fn with_origin(mut self, origin: Option<ColumnOrigin>) -> Self {
        self.origin = origin;
        self
    }
}
