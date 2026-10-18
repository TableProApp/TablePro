use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use tablepro_session::{ConnectionMetadata, Session};

/// The window's current session, shared by every view on the GTK thread.
///
/// Views hold a clone of this handle rather than the session itself, so
/// a disconnect or a switch to another database reaches all of them at
/// once and none keeps a closed session alive.
#[derive(Debug, Clone, Default)]
pub struct ActiveSession {
    current: Rc<RefCell<Option<Arc<Session>>>>,
}

impl ActiveSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self) -> Option<Arc<Session>> {
        self.current.borrow().clone()
    }

    pub fn replace(&self, session: Arc<Session>) -> Option<Arc<Session>> {
        self.current.borrow_mut().replace(session)
    }

    pub fn take(&self) -> Option<Arc<Session>> {
        self.current.borrow_mut().take()
    }

    pub fn is_connected(&self) -> bool {
        self.current.borrow().is_some()
    }

    pub fn metadata(&self) -> Option<ConnectionMetadata> {
        self.current.borrow().as_ref().map(|session| session.metadata().clone())
    }

    /// What the connection enforces. False with no session, because
    /// nothing can be written then anyway.
    pub fn read_only(&self) -> bool {
        self.current
            .borrow()
            .as_ref()
            .is_some_and(|session| session.read_only())
    }
}
