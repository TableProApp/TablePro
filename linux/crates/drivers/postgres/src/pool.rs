use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod, Runtime, Timeouts};
use tablepro_core::{DriverError, LivenessPolicy};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::task::JoinHandle;
use tokio_postgres::config::SslMode;
use tokio_postgres::{Client, Config, NoTls};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::debug;

use crate::physical::PgEndpoint;

/// The workspace pool's size. Exported so the conformance suite proves
/// saturation against the driver's own number rather than deadpool's
/// default, which follows the host's core count.
pub const WORKSPACE_POOL_MAX_SIZE: usize = 4;

type ConnectFuture<'a> =
    Pin<Box<dyn Future<Output = Result<(Client, JoinHandle<()>), tokio_postgres::Error>> + Send + 'a>>;

/// deadpool-postgres's connect hook, opening every pool member over the
/// target's transport instead of the host and port in its `Config`.
pub(crate) struct PgConnect {
    endpoint: Arc<PgEndpoint>,
    tracker: TaskTracker,
}

impl deadpool_postgres::Connect for PgConnect {
    fn connect(&self, _: &Config) -> ConnectFuture<'_> {
        Box::pin(async move {
            match self.endpoint.open(&CancellationToken::new()).await {
                Ok((client, connection)) => {
                    let driving = self.tracker.spawn(async move {
                        if let Err(error) = connection.await {
                            debug!(%error, "a pooled PostgreSQL connection ended");
                        }
                    });
                    Ok((client, driving))
                }
                Err(error) => Err(carry(error).await),
            }
        })
    }
}

pub(crate) fn build_pool(endpoint: Arc<PgEndpoint>, tracker: TaskTracker) -> Result<Pool, DriverError> {
    let liveness = *endpoint.liveness();
    let manager = Manager::from_connect(
        Config::new(),
        PgConnect { endpoint, tracker },
        ManagerConfig {
            recycling_method: RecyclingMethod::Verified,
        },
    );
    let timeouts = workspace_timeouts(&liveness);
    Pool::builder(manager)
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

/// deadpool's `Connect` can only fail with a tokio-postgres error, which
/// has no public constructor. The real error rides in the `io::Error`
/// of a stream that fails on its first write, so `errors::map_error`
/// finds it again at the other end of the pool.
async fn carry(error: DriverError) -> tokio_postgres::Error {
    let mut config = Config::new();
    config.ssl_mode(SslMode::Disable).user("tablepro");
    let mut carrier = Some(io::Error::other(error));
    loop {
        let stream = FailingStream(carrier.take());
        if let Err(error) = config.connect_raw(stream, NoTls).await {
            return error;
        }
        // The stream fails its first write, so a login over it cannot
        // succeed; this only satisfies the type.
        carrier = Some(io::Error::other("the carrier stream accepted a login"));
    }
}

struct FailingStream(Option<io::Error>);

impl FailingStream {
    fn failure(&mut self) -> io::Error {
        self.0
            .take()
            .unwrap_or_else(|| io::Error::from(io::ErrorKind::BrokenPipe))
    }
}

impl AsyncRead for FailingStream {
    fn poll_read(mut self: Pin<&mut Self>, _: &mut Context<'_>, _: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Err(self.failure()))
    }
}

impl AsyncWrite for FailingStream {
    fn poll_write(mut self: Pin<&mut Self>, _: &mut Context<'_>, _: &[u8]) -> Poll<io::Result<usize>> {
        Poll::Ready(Err(self.failure()))
    }

    fn poll_flush(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Err(self.failure()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{LossPhase, TimeoutPhase, TransportError};

    use super::*;
    use crate::errors::map_error;

    #[tokio::test]
    async fn a_carried_error_comes_back_as_it_went_in() {
        let sent = DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        });

        let carried = carry(sent.clone()).await;

        assert_eq!(map_error(&carried), sent);
        let lost = DriverError::ConnectionLost {
            during: LossPhase::Connect,
        };
        assert_eq!(map_error(&carry(lost.clone()).await), lost);
    }

    #[test]
    fn the_probe_never_waits_for_a_slot() {
        let timeouts = probe_timeouts(&LivenessPolicy::DESKTOP);

        assert_eq!(timeouts.wait, Some(Duration::ZERO));
        assert_eq!(
            workspace_timeouts(&LivenessPolicy::DESKTOP).wait,
            Some(LivenessPolicy::DESKTOP.pool_wait)
        );
    }
}
