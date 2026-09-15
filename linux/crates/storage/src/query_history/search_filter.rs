use std::time::SystemTime;

use uuid::Uuid;

#[derive(Debug, Clone, Default)]
pub struct SearchFilter {
    pub needle: Option<String>,
    pub connection_id: Option<Uuid>,
    pub success_only: Option<bool>,
    pub exclude_cancelled: Option<bool>,
    pub min_executed_at: Option<SystemTime>,
    pub limit: usize,
}
