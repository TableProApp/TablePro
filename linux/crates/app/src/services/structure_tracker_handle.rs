use std::cell::RefCell;
use std::rc::Rc;

use super::pending_structure::PendingStructure;
use super::structure_tracker::StructureChangeTracker;

/// A Structure tab's pending save. Every method borrows only for its own
/// body and returns owned data.
#[derive(Debug, Clone, Default)]
pub struct StructureTrackerHandle(Rc<RefCell<StructureChangeTracker>>);

impl StructureTrackerHandle {
    pub fn set_pending(&self, pending: Option<PendingStructure>) {
        self.0.borrow_mut().set_pending(pending);
    }

    pub fn begin_save(&self) -> Option<PendingStructure> {
        self.0.borrow().begin_save()
    }

    pub fn has_pending(&self) -> bool {
        self.0.borrow().has_pending()
    }

    pub fn clear(&self) {
        self.0.borrow_mut().clear();
    }
}
