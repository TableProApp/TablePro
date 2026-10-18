use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

/// How many times each `Connection` method was called, shared with the
/// test after the connection has been handed to the code under test.
#[derive(Debug, Clone, Default)]
pub struct CallCounters {
    pub probe: Arc<AtomicUsize>,
    pub list_schemas: Arc<AtomicUsize>,
    pub list_objects: Arc<AtomicUsize>,
    pub fetch_columns: Arc<AtomicUsize>,
    pub fetch_indexes: Arc<AtomicUsize>,
    pub fetch_foreign_keys: Arc<AtomicUsize>,
    pub fetch_table_definition: Arc<AtomicUsize>,
    pub row_identity: Arc<AtomicUsize>,
    pub table_estimate: Arc<AtomicUsize>,
    pub query_bound: Arc<AtomicUsize>,
    pub count_rows: Arc<AtomicUsize>,
    pub stream_read: Arc<AtomicUsize>,
    pub write_batch: Arc<AtomicUsize>,
    pub resolve_commit: Arc<AtomicUsize>,
    pub open_editor_session: Arc<AtomicUsize>,
    pub close: Arc<AtomicUsize>,
    /// Calls that ended because their cancel or deadline fired, or the
    /// connection was closed under them.
    pub stopped: Arc<AtomicUsize>,
}

impl CallCounters {
    pub fn get(counter: &AtomicUsize) -> usize {
        counter.load(Ordering::SeqCst)
    }

    pub(crate) fn record(counter: &AtomicUsize) {
        counter.fetch_add(1, Ordering::SeqCst);
    }
}
