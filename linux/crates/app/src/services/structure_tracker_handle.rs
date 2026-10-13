use std::cell::RefCell;
use std::rc::Rc;

use tablepro_core::sql_ddl::StructureOp;

use super::structure_tracker::StructureChangeTracker;

/// A Structure tab's cached DDL. Every method borrows only for its own
/// body and returns owned data.
#[derive(Debug, Clone, Default)]
pub struct StructureTrackerHandle(Rc<RefCell<StructureChangeTracker>>);

impl StructureTrackerHandle {
    pub fn set_ops(&self, ops: Vec<StructureOp>) {
        self.0.borrow_mut().set_ops(ops);
    }

    pub fn ops(&self) -> Vec<StructureOp> {
        self.0.borrow().ops().to_vec()
    }

    pub fn has_pending(&self) -> bool {
        self.0.borrow().has_pending()
    }

    pub fn clear(&self) {
        self.0.borrow_mut().clear();
    }
}
