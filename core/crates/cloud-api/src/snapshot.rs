use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

// The document's SnapshotBody, which build.rs puts in place of the generated one: its rows go out as the raw JSON
// tokens the core wrote, where the generated `serde_json::Value` would round a big number.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapshotBody {
    pub columns: Vec<SnapshotColumnBody>,
    pub rows: Vec<Vec<Box<RawValue>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_count: Option<i64>,
    // Rows exist beyond those sent and nobody counted them; the viewer then says so rather than read the rows as
    // the whole result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub more_rows: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotColumnBody {
    pub name: String,
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub type_name: Option<String>,
    // The document's ShareMaskStyle: how the app masked the column's values before they left it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub masked: Option<String>,
}

// The document's PublicSnapshot, which build.rs puts in place of the generated one. Only the counts are read: the
// app opens a link's SQL, so its rows are skipped rather than parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicSnapshot {
    // None for a result cut with no count.
    #[serde(default)]
    pub row_count: Option<i64>,
    pub truncated: bool,
}
