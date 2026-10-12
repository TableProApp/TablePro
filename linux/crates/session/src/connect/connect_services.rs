use tablepro_core::{ConnectEnvironment, LivenessPolicy};
use tablepro_ssh::SshServices;

/// What every connect needs from the app: who is connecting, how SSH is
/// run, and the liveness bounds.
#[derive(Debug, Clone)]
pub struct ConnectServices {
    pub environment: ConnectEnvironment,
    pub ssh: SshServices,
    pub liveness: LivenessPolicy,
}
