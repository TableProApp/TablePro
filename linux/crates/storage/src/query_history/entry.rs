use std::time::SystemTime;

use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Entry {
    pub id: i64,
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub success: bool,
    pub cancelled: bool,
    pub pinned: bool,
    pub error: Option<String>,
}
