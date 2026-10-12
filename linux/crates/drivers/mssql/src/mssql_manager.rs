use std::sync::Arc;
use std::time::Duration;

use deadpool::Runtime;
use deadpool::managed::{Manager, Metrics, Pool, RecycleError, RecycleResult, Timeouts};
use tablepro_core::{DriverError, LivenessPolicy};
use tokio_util::sync::CancellationToken;

use crate::endpoint::MssqlEndpoint;
use crate::physical::MssqlLink;

/// The workspace pool's size. Exported so the conformance suite proves
/// saturation against the driver's own number.
pub const WORKSPACE_POOL_MAX_SIZE: usize = 4;

pub(crate) type MssqlPool = Pool<MssqlManager>;

/// deadpool's manager for workspace connections, on the documented
/// trait: no maintained manager exists for tiberius.
pub(crate) struct MssqlManager {
    endpoint: Arc<MssqlEndpoint>,
}

impl Manager for MssqlManager {
    type Type = MssqlLink;
    type Error = DriverError;

    async fn create(&self) -> Result<MssqlLink, DriverError> {
        self.endpoint.open_workspace(&CancellationToken::new()).await
    }

    /// A connection goes back into use only with no transaction open.
    /// One whose call did not end cleanly never gets here: the call
    /// takes it out of the pool itself.
    async fn recycle(&self, link: &mut MssqlLink, _: &Metrics) -> RecycleResult<DriverError> {
        match link.transaction_count().await {
            Ok(0) => Ok(()),
            Ok(open) => Err(RecycleError::message(format!("{open} transactions were left open"))),
            Err(error) => Err(RecycleError::Backend(error)),
        }
    }
}

pub(crate) fn build_pool(endpoint: Arc<MssqlEndpoint>) -> Result<MssqlPool, DriverError> {
    let timeouts = workspace_timeouts(endpoint.liveness());
    Pool::builder(MssqlManager { endpoint })
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
        assert_eq!(timeouts.recycle, Some(LivenessPolicy::DESKTOP.probe_timeout));
    }
}
