use std::sync::Arc;
use std::time::Duration;

use deadpool::Runtime;
use deadpool::managed::{Manager, Metrics, Pool, RecycleError, RecycleResult, Timeouts};
use sqlx::Connection as _;
use tablepro_core::{DriverError, LivenessPolicy};
use tokio_util::sync::CancellationToken;

use crate::errors::map_error;
use crate::physical::{MySqlPhysical, MysqlEndpoint, SessionKind};
use crate::session_statements::SessionLimits;

/// The workspace pool's size. Exported so the conformance suite proves
/// saturation against the driver's own number rather than deadpool's
/// default, which follows the host's core count.
pub const WORKSPACE_POOL_MAX_SIZE: usize = 4;

pub(crate) type MysqlPool = Pool<MysqlManager>;

/// deadpool's manager for workspace connections: each member is a login
/// with the workspace session already set up.
pub(crate) struct MysqlManager {
    endpoint: Arc<MysqlEndpoint>,
    limits: SessionLimits,
}

impl Manager for MysqlManager {
    type Type = MySqlPhysical;
    type Error = DriverError;

    async fn create(&self) -> Result<MySqlPhysical, DriverError> {
        self.endpoint
            .connect_physical(SessionKind::Workspace, &self.limits, &CancellationToken::new())
            .await
    }

    /// A member is handed out again only once the server has answered a
    /// ping. A member whose call was abandoned never gets here: the call
    /// takes it out of the pool instead.
    async fn recycle(&self, member: &mut MySqlPhysical, _: &Metrics) -> RecycleResult<DriverError> {
        let bound = self.endpoint.liveness().probe_timeout;
        match tokio::time::timeout(bound, member.connection.ping()).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => Err(RecycleError::Backend(map_error(&error, member.flavour))),
            Err(_) => Err(RecycleError::message("the server did not answer a ping in time")),
        }
    }
}

pub(crate) fn build_pool(endpoint: Arc<MysqlEndpoint>, limits: SessionLimits) -> Result<MysqlPool, DriverError> {
    let timeouts = workspace_timeouts(endpoint.liveness());
    Pool::builder(MysqlManager { endpoint, limits })
        .max_size(WORKSPACE_POOL_MAX_SIZE)
        .wait_timeout(timeouts.wait)
        .create_timeout(timeouts.create)
        .recycle_timeout(timeouts.recycle)
        .runtime(Runtime::Tokio1)
        .build()
        .map_err(|error| DriverError::Protocol(error.to_string()))
}

pub(crate) fn workspace_timeouts(liveness: &LivenessPolicy) -> Timeouts {
    Timeouts {
        wait: Some(liveness.pool_wait),
        create: Some(liveness.connect_timeout + liveness.login_timeout),
        recycle: Some(liveness.probe_timeout),
    }
}

/// The probe never waits for a slot: a busy pool is not a dead server.
pub(crate) fn probe_timeouts(liveness: &LivenessPolicy) -> Timeouts {
    Timeouts {
        wait: Some(Duration::ZERO),
        ..workspace_timeouts(liveness)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_probe_never_waits_for_a_slot() {
        let timeouts = probe_timeouts(&LivenessPolicy::DESKTOP);

        assert_eq!(timeouts.wait, Some(Duration::ZERO));
        assert_eq!(
            workspace_timeouts(&LivenessPolicy::DESKTOP).wait,
            Some(LivenessPolicy::DESKTOP.pool_wait)
        );
        assert_eq!(
            timeouts.recycle,
            Some(LivenessPolicy::DESKTOP.probe_timeout),
            "a recycle ping is a probe"
        );
    }
}
