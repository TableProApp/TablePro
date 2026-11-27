use std::time::SystemTime;

use uuid::Uuid;

use super::RunDetails;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    // The rowid the full-text index joins on, which pages and pins use and which never leaves the device.
    pub id: i64,
    // The id the entry syncs under, random so it says nothing of when the query ran (core ADR 0052).
    pub record_id: Uuid,
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_us: Option<i64>,
    pub rows_affected: Option<i64>,
    pub success: bool,
    pub cancelled: bool,
    pub pinned: bool,
    pub error: Option<String>,
    pub details: RunDetails,
}
