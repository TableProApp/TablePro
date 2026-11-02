use crate::connect_environment::ConnectEnvironment;
use crate::connect_target::ConnectTarget;
use crate::liveness_policy::LivenessPolicy;
use crate::workspace_settings::WorkspaceSettings;

/// Everything a driver needs to open a connection.
///
/// There is no default: a connection opened with a made-up host, an
/// empty password or a missing timeout is a bug that should not
/// compile.
#[derive(Debug, Clone)]
pub struct ConnectOptions {
    pub target: ConnectTarget,
    pub workspace_settings: WorkspaceSettings,
    pub liveness: LivenessPolicy,
    pub environment: ConnectEnvironment,
}
