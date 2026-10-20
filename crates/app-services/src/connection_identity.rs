use std::sync::{Arc, Weak};

use tablepro_core::Connection;

#[derive(Debug, Clone)]
pub struct ConnectionIdentity(Weak<dyn Connection>);

impl ConnectionIdentity {
    pub fn from_connection(connection: &Arc<dyn Connection>) -> Self {
        Self(Arc::downgrade(connection))
    }
}

impl PartialEq for ConnectionIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.0.ptr_eq(&other.0)
    }
}

impl Eq for ConnectionIdentity {}
