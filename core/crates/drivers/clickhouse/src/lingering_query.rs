use std::sync::{Mutex, PoisonError};

use uuid::Uuid;

/// The last query an editor session told the server to stop.
///
/// The server may still be ending it after the run has given up its
/// response, and until it has, the session refuses another query with
/// 373. So the next run waits for it first.
#[derive(Debug, Default)]
pub(crate) struct LingeringQuery(Mutex<Option<Uuid>>);

impl LingeringQuery {
    pub(crate) fn left(&self, query_id: Uuid) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = Some(query_id);
    }

    /// The server ended the response, and with it the query, so the
    /// session is free.
    pub(crate) fn ended(&self, query_id: Uuid) {
        let mut lingering = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if *lingering == Some(query_id) {
            *lingering = None;
        }
    }

    pub(crate) fn take(&self) -> Option<Uuid> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}
