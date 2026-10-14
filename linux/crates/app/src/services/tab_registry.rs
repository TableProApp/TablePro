use std::cell::RefCell;
use std::collections::HashMap;

use uuid::Uuid;

/// One workspace's trackers, keyed by tab. Each window owns its own, so
/// edits in one window never count as unsaved in another.
#[derive(Debug)]
pub struct TabRegistry<H> {
    trackers: RefCell<HashMap<Uuid, H>>,
}

impl<H> Default for TabRegistry<H> {
    fn default() -> Self {
        Self {
            trackers: RefCell::new(HashMap::new()),
        }
    }
}

impl<H: Clone + Default> TabRegistry<H> {
    /// The tab's tracker, created on first use.
    pub fn register(&self, tab_id: Uuid) -> H {
        self.trackers.borrow_mut().entry(tab_id).or_default().clone()
    }

    pub fn unregister(&self, tab_id: Uuid) {
        self.trackers.borrow_mut().remove(&tab_id);
    }

    pub fn get(&self, tab_id: Uuid) -> Option<H> {
        self.trackers.borrow().get(&tab_id).cloned()
    }
}
