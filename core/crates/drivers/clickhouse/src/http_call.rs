use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use tablepro_core::CallResource;

/// What one workspace call holds while it runs.
///
/// Over HTTP the connection belongs to the request: hyper returns it to
/// its pool only after a response was read to the end, and closes it
/// when a request is dropped half-read. So there is nothing to take out
/// of a pool here, and the abandon flag is all `OwnedCalls` needs.
pub(crate) struct HttpCall {
    abandon: Arc<AtomicBool>,
}

impl HttpCall {
    pub(crate) fn new() -> Self {
        Self {
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl CallResource for HttpCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(self) {}
}
