use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio_util::sync::CancellationToken;

use tablepro_core::Connection;
use tablepro_ssh::russh_tunnel::SshTunnel;

use super::connection_service;
use super::database_service::{ConnectionHealth, EntryInner, ReconnectParams};

const PING_INTERVAL: Duration = Duration::from_secs(30);
const BACKOFF_INITIAL: Duration = Duration::from_secs(5);
const BACKOFF_MAX: Duration = Duration::from_secs(60);

pub(super) async fn run(inner: Arc<Mutex<EntryInner>>, params: ReconnectParams, cancel: CancellationToken) {
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(PING_INTERVAL) => {}
        }

        let conn = match snapshot_connection(&inner) {
            Some(c) => c,
            None => return,
        };

        if let Err(e) = conn.ping().await {
            tracing::warn!(error = %e, "connection ping failed; starting reconnect");
            if reconnect_loop(&inner, &params, &cancel).await.is_err() {
                return;
            }
        }
    }
}

fn snapshot_connection(inner: &Arc<Mutex<EntryInner>>) -> Option<Arc<dyn Connection>> {
    inner.lock().ok().map(|g| g.connection.clone())
}

async fn reconnect_loop(
    inner: &Arc<Mutex<EntryInner>>,
    params: &ReconnectParams,
    cancel: &CancellationToken,
) -> Result<(), ()> {
    let mut delay = BACKOFF_INITIAL;
    let mut attempt: u32 = 1;
    set_health(inner, ConnectionHealth::Reconnecting { attempt });
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return Err(()),
            _ = tokio::time::sleep(delay) => {}
        }

        match try_reconnect(params).await {
            Ok((conn, tunnel)) => {
                swap_connection(inner, conn, tunnel);
                set_health(inner, ConnectionHealth::Healthy);
                tracing::info!(attempt, "reconnect succeeded");
                return Ok(());
            }
            Err(e) => {
                tracing::warn!(error = %e, attempt, delay_secs = delay.as_secs(), "reconnect failed; backing off");
                attempt += 1;
                set_health(inner, ConnectionHealth::Reconnecting { attempt });
                delay = next_delay(delay);
            }
        }
    }
}

fn next_delay(prev: Duration) -> Duration {
    std::cmp::min(prev.saturating_mul(2), BACKOFF_MAX)
}

async fn try_reconnect(params: &ReconnectParams) -> Result<(Box<dyn Connection>, Option<SshTunnel>), String> {
    connection_service::establish(
        params.driver.as_ref(),
        params.opts.clone(),
        params.ssh.clone(),
        params.read_only,
    )
    .await
}

fn swap_connection(inner: &Arc<Mutex<EntryInner>>, conn: Box<dyn Connection>, tunnel: Option<SshTunnel>) {
    let arc: Arc<dyn Connection> = Arc::from(conn);
    if let Ok(mut g) = inner.lock() {
        g.connection = arc;
        g.tunnel = tunnel;
    }
}

fn set_health(inner: &Arc<Mutex<EntryInner>>, health: ConnectionHealth) {
    if let Ok(mut g) = inner.lock() {
        g.health = health;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_until_capped() {
        let mut d = BACKOFF_INITIAL;
        assert_eq!(d, Duration::from_secs(5));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(10));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(20));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(40));
        d = next_delay(d);
        assert_eq!(d, BACKOFF_MAX);
        d = next_delay(d);
        assert_eq!(d, BACKOFF_MAX);
    }

    #[test]
    fn backoff_saturates_without_overflow() {
        assert_eq!(next_delay(Duration::MAX), BACKOFF_MAX);
    }
}
