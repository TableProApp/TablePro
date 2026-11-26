// The engine signals from inside its passes and flows, some under its own locks. The app's listener hears them from a
// task of its own, so no foreign call runs under a lock (core ADR 0002), and a burst of signals reaches it as one.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tablepro_session::runtime::Tasks;
use tablepro_sync::engine::EngineEvents;
use tokio::sync::Notify;
use tokio_util::task::AbortOnDropHandle;

use super::service::SyncListener;

#[derive(Debug, Default)]
pub(crate) struct Signals {
    status: AtomicBool,
    keys: AtomicBool,
    raised: Notify,
}

impl EngineEvents for Signals {
    fn status_changed(&self) {
        self.status.store(true, Ordering::SeqCst);
        self.raised.notify_one();
    }

    fn keys_changed(&self) {
        self.keys.store(true, Ordering::SeqCst);
        self.raised.notify_one();
    }
}

// Ends when the handle drops, with the service.
pub(crate) fn forward(signals: Arc<Signals>, listener: Arc<dyn SyncListener>, tasks: &Tasks) -> AbortOnDropHandle<()> {
    tasks.spawn_owned(async move {
        loop {
            signals.raised.notified().await;
            if signals.status.swap(false, Ordering::SeqCst) {
                listener.status_changed();
            }
            if signals.keys.swap(false, Ordering::SeqCst) {
                listener.keys_changed();
            }
        }
    })
}
