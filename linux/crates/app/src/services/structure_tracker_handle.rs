use std::cell::RefCell;
use std::rc::Rc;

use super::pending_structure::PendingStructure;
use super::structure_tracker::StructureChangeTracker;
use crate::workspace::{PendingState, SaveOutcome, SaveRejection};

/// A Structure tab's pending save. Every method borrows only for its own
/// body and returns owned data.
#[derive(Debug, Clone, Default)]
pub struct StructureTrackerHandle(Rc<RefCell<StructureChangeTracker>>);

impl StructureTrackerHandle {
    pub fn set_pending(&self, pending: Option<PendingStructure>) {
        self.0.borrow_mut().set_pending(pending);
    }

    pub fn begin_save(&self) -> Result<Option<PendingStructure>, SaveRejection> {
        self.0.borrow_mut().begin_save()
    }

    pub fn settle_save(&self, outcome: &SaveOutcome) {
        self.0.borrow_mut().settle_save(outcome);
    }

    pub fn pending_state(&self) -> PendingState {
        self.0.borrow().pending_state()
    }

    pub fn is_saving(&self) -> bool {
        self.0.borrow().is_saving()
    }

    pub fn has_pending(&self) -> bool {
        self.0.borrow().has_pending()
    }

    pub fn clear(&self) {
        self.0.borrow_mut().clear();
    }
}
