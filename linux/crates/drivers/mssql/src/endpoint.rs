use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{DriverError, LivenessPolicy, NetworkTarget, TimeoutPhase, Transport, WorkspaceSettings};
use tokio_util::sync::CancellationToken;

use crate::login::{LoginPlan, login};
use crate::physical::MssqlLink;

/// Everything needed to open a physical connection to one server.
///
/// Every stream comes from the transport, so the driver never learns
/// whether the server is reached directly or through an SSH forward.
pub(crate) struct MssqlEndpoint {
    transport: Arc<dyn Transport>,
    plan: LoginPlan,
    liveness: LivenessPolicy,
    workspace_setup: String,
}

impl MssqlEndpoint {
    pub(crate) fn new(
        target: &NetworkTarget,
        liveness: LivenessPolicy,
        settings: &WorkspaceSettings,
    ) -> Result<Self, DriverError> {
        Ok(Self {
            transport: target.transport.clone(),
            plan: LoginPlan::new(target, &liveness)?,
            liveness,
            workspace_setup: workspace_setup(settings),
        })
    }

    pub(crate) fn liveness(&self) -> &LivenessPolicy {
        &self.liveness
    }

    /// A connection for the workspace pool, with the session settings
    /// every driver-owned statement relies on.
    pub(crate) async fn open_workspace(&self, cancel: &CancellationToken) -> Result<MssqlLink, DriverError> {
        let mut link = self.open(cancel).await?;
        let setting_up = link.batch(&self.workspace_setup);
        let set_up = tokio::select! {
            biased;
            () = cancel.cancelled() => Err(DriverError::Cancelled),
            set_up = tokio::time::timeout(self.liveness.login_timeout, setting_up) => {
                set_up.unwrap_or(Err(DriverError::Timeout { phase: TimeoutPhase::Login, server_cancelled: false }))
            }
        };
        match set_up {
            Ok(()) => Ok(link),
            Err(error) => Err(self.explain(error).await),
        }
    }

    /// A connection for an editor tab, left at the server's defaults
    /// because whatever the user sets on it is theirs.
    pub(crate) async fn open_editor(&self, cancel: &CancellationToken) -> Result<MssqlLink, DriverError> {
        self.open(cancel).await
    }

    async fn open(&self, cancel: &CancellationToken) -> Result<MssqlLink, DriverError> {
        match login(&self.plan, self.transport.clone(), cancel).await {
            Ok(link) => Ok(link),
            Err(error) => Err(self.explain(error).await),
        }
    }

    /// A stream that closed may be the transport's doing, such as an SSH
    /// master that exited, which says more than "connection lost".
    pub(crate) async fn explain(&self, error: DriverError) -> DriverError {
        if !matches!(error, DriverError::ConnectionLost { .. }) {
            return error;
        }
        match self.transport.explain_closed_stream().await {
            Some(transport) => DriverError::Transport(transport),
            None => error,
        }
    }

    /// Open a connection of its own and ask it one trivial question,
    /// within `bound`. This is the probe that never waits for a pool.
    pub(crate) async fn check(&self, bound: Duration) -> Result<(), DriverError> {
        let checking = async {
            let mut link = self.open(&CancellationToken::new()).await?;
            link.batch("SELECT 1").await
        };
        match tokio::time::timeout(bound, checking).await {
            Ok(outcome) => outcome,
            Err(_) => Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false,
            }),
        }
    }
}

/// What a workspace connection runs once, after login.
///
/// XACT_ABORT rolls a transaction back on any error and on a client's
/// attention, so a statement the app stops never leaves one open on a
/// pooled connection. LOCK_TIMEOUT makes a blocked edit report the lock
/// rather than run into the statement deadline.
fn workspace_setup(settings: &WorkspaceSettings) -> String {
    let lock_timeout = settings.lock_timeout.as_millis().clamp(1, i32::MAX as u128);
    format!("SET LOCK_TIMEOUT {lock_timeout}; SET XACT_ABORT ON;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_sessions_abort_on_error_and_bound_lock_waits() {
        let setup = workspace_setup(&WorkspaceSettings::workspace(false));

        assert_eq!(setup, "SET LOCK_TIMEOUT 10000; SET XACT_ABORT ON;");
    }

    #[test]
    fn a_sub_millisecond_lock_timeout_never_renders_as_no_wait() {
        let settings = WorkspaceSettings {
            lock_timeout: Duration::from_micros(10),
            ..WorkspaceSettings::workspace(false)
        };

        assert!(workspace_setup(&settings).starts_with("SET LOCK_TIMEOUT 1;"));
    }
}
