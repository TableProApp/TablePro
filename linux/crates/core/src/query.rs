use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableInfo {
    pub schema: Option<String>,
    pub name: String,
}

/// Secondary-index metadata for a table. `primary` is set on the
/// auto-PK index returned by the catalog query so the UI can render
/// it as read-only (the PK is owned by the column definition, not
/// by an editable index entry).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub unique: bool,
    pub primary: bool,
}

/// Foreign-key constraint metadata. `on_delete` / `on_update` carry
/// the referential action as a normalised SQL keyword string
/// ("RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION").
/// `None` means the driver returned a value we don't recognise — the
/// UI displays it as a dim-label "—" and the DDL builder omits the
/// clause so the database picks its default.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForeignKeyInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<String>,
    pub on_update: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct ExecResult {
    pub rows_affected: u64,
}
