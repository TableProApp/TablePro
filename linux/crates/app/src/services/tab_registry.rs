use std::cell::RefCell;
use std::collections::HashMap;

use uuid::Uuid;

/// A tab's tracker as a workspace registry holds it.
pub trait TrackerHandle: Clone + Default {
    fn has_pending(&self) -> bool;
}

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

impl<H: TrackerHandle> TabRegistry<H> {
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

    /// Tabs with unsaved changes, in a stable order.
    pub fn dirty(&self) -> Vec<Uuid> {
        let mut dirty: Vec<Uuid> = self
            .trackers
            .borrow()
            .iter()
            .filter(|(_, tracker)| tracker.has_pending())
            .map(|(tab_id, _)| *tab_id)
            .collect();
        dirty.sort_unstable();
        dirty
    }
}
