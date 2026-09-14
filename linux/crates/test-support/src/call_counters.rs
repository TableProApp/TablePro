use std::sync::Arc;
use std::sync::atomic::AtomicUsize;

#[derive(Debug, Clone, Default)]
pub struct CallCounters {
    pub list_tables: Arc<AtomicUsize>,
    pub fetch_columns: Arc<AtomicUsize>,
    pub fetch_rows: Arc<AtomicUsize>,
    pub query: Arc<AtomicUsize>,
    pub execute: Arc<AtomicUsize>,
    pub execute_params: Arc<AtomicUsize>,
    pub execute_in_transaction: Arc<AtomicUsize>,
    pub ping: Arc<AtomicUsize>,
    pub close: Arc<AtomicUsize>,
}
