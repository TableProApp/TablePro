use std::fmt;
use std::sync::Arc;

use tablepro_core::{DatabaseDriver, WorkspaceSettings};

use super::{ConnectionMetadata, RequestTarget};

/// Everything one connect attempt needs, secrets included.
#[derive(Clone)]
pub struct ConnectRequest {
    pub metadata: ConnectionMetadata,
    pub driver: Arc<dyn DatabaseDriver>,
    pub target: RequestTarget,
    pub workspace_settings: WorkspaceSettings,
}

impl ConnectRequest {
    /// The request a reconnect sends: the same server, user and
    /// settings, never a retarget.
    pub fn for_reconnect(&self) -> Self {
        Self {
            target: self.target.for_reconnect(),
            ..self.clone()
        }
    }
}

/// Only what identifies the request: a log line must never carry a host
/// list or a user name the user did not choose to share.
impl fmt::Debug for ConnectRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConnectRequest")
            .field("id", &self.metadata.id)
            .field("name", &self.metadata.name)
            .finish_non_exhaustive()
    }
}
