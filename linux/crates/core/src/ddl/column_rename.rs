/// A kept column that changed its name.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ColumnRename {
    pub from: String,
    pub to: String,
}
