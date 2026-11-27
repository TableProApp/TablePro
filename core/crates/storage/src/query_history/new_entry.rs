use std::time::SystemTime;

use uuid::Uuid;

use super::{Outcome, RunDetails};

#[derive(Debug, Clone)]
pub struct NewEntry {
    // A new UUIDv4 for a run this device saw; the entry's own for one a pull or another store brings.
    pub record_id: Uuid,
    pub query: String,
    pub driver_id: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub executed_at: SystemTime,
    pub duration_us: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: Outcome,
    pub details: RunDetails,
}
