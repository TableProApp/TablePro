use std::time::SystemTime;

use uuid::Uuid;

use super::Outcome;

#[derive(Debug, Clone)]
pub struct NewEntry {
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: Outcome,
}
