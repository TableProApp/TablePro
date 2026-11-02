use std::sync::Arc;

use tablepro_core::{ConnectEnvironment, LivenessPolicy};

use super::SshTunnels;

/// What every connect needs from the app: who is connecting, how SSH is
/// run, and the liveness bounds.
#[derive(Debug, Clone)]
pub struct ConnectServices {
    pub environment: ConnectEnvironment,
    pub ssh: Arc<dyn SshTunnels>,
    pub liveness: LivenessPolicy,
}
