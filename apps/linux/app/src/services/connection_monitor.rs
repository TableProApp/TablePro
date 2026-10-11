use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use tablepro_core::Connection;
use tablepro_transport::Tunnel;

use super::connection_service;
use super::database_service::{ConnectionHealth, EntryInner, ReconnectParams};
#[cfg(test)]
use tablepro_policy::AuditState;

const PING_INTERVAL: Duration = Duration::from_secs(30);
const TUNNEL_POLL_INTERVAL: Duration = Duration::from_secs(1);
const BACKOFF_INITIAL: Duration = Duration::from_secs(5);
const BACKOFF_MAX: Duration = Duration::from_secs(60);

pub(super) async fn run(
    inner: Arc<Mutex<EntryInner>>,
    params: ReconnectParams,
    cancel: CancellationToken,
    fault: Arc<Notify>,
) {
    loop {
        let wake = tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(PING_INTERVAL) => Wake::Ping,
            _ = fault.notified() => Wake::Fault,
            _ = wait_for_closed_tunnel(&inner) => Wake::TunnelClosed,
        };

        if matches!(wake, Wake::Fault | Wake::TunnelClosed) {
            if matches!(wake, Wake::TunnelClosed) {
                tracing::warn!("SSH tunnel closed; starting reconnect");
            }
            if reconnect_loop(&inner, &params, &cancel, &fault).await.is_err() {
                return;
            }
            continue;
        }

        let conn = match snapshot_connection(&inner) {
            Some(c) => c,
            None => return,
        };

        let ping_result = tokio::select! {
            _ = cancel.cancelled() => return,
            _ = fault.notified() => Err(PingFailure::Reported),
            _ = wait_for_closed_tunnel(&inner) => Err(PingFailure::TunnelClosed),
            result = conn.ping() => result.map_err(PingFailure::Driver),
        };
        let reconnect = ping_result.is_err();
        match ping_result {
            Ok(()) => {}
            Err(PingFailure::Driver(error)) => {
                tracing::warn!(error = %error, "connection ping failed; starting reconnect");
            }
            Err(PingFailure::Reported) => {
                tracing::warn!("connection reported a transport fault; starting reconnect");
            }
            Err(PingFailure::TunnelClosed) => {
                tracing::warn!("SSH tunnel closed during ping; starting reconnect");
            }
        }
        if reconnect && reconnect_loop(&inner, &params, &cancel, &fault).await.is_err() {
            return;
        }
    }
}

#[derive(Clone, Copy)]
enum Wake {
    Ping,
    Fault,
    TunnelClosed,
}

enum PingFailure {
    Driver(tablepro_core::DriverError),
    Reported,
    TunnelClosed,
}

async fn wait_for_closed_tunnel(inner: &Arc<Mutex<EntryInner>>) {
    wait_until_closed(|| {
        inner
            .lock()
            .ok()
            .and_then(|entry| entry.tunnel.as_ref().map(Tunnel::is_closed))
    })
    .await;
}

async fn wait_until_closed(mut tunnel_is_closed: impl FnMut() -> Option<bool>) {
    loop {
        match tunnel_is_closed() {
            Some(true) => return,
            Some(false) => tokio::time::sleep(TUNNEL_POLL_INTERVAL).await,
            None => std::future::pending().await,
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
    fault: &Arc<Notify>,
) -> Result<(), ()> {
    let mut delay = BACKOFF_INITIAL;
    let mut attempt: u32 = 1;
    set_health(inner, ConnectionHealth::Reconnecting { attempt });
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return Err(()),
            _ = tokio::time::sleep(delay) => {}
        }

        match try_reconnect(params, cancel).await {
            Err(failure) if failure.permanent => {
                tracing::warn!(error = %failure.message, attempt, "reconnect cannot succeed; giving up");
                set_health(
                    inner,
                    ConnectionHealth::Failed {
                        reason: failure.message,
                    },
                );
                return Err(());
            }
            Ok((conn, tunnel)) => {
                swap_connection(inner, conn, tunnel, fault);
                set_health(inner, ConnectionHealth::Healthy);
                tracing::info!(attempt, "reconnect succeeded");
                return Ok(());
            }
            Err(failure) => {
                tracing::warn!(error = %failure.message, attempt, delay_secs = delay.as_secs(), "reconnect failed; backing off");
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

async fn try_reconnect(
    params: &ReconnectParams,
    cancel: &CancellationToken,
) -> Result<(Box<dyn Connection>, Option<Tunnel>), connection_service::EstablishFailure> {
    connection_service::establish_classified_with_cancellation(
        params.driver.as_ref(),
        params.opts.clone(),
        params.ssh.clone(),
        &params.environment,
        cancel.clone(),
    )
    .await
}

fn swap_connection(
    inner: &Arc<Mutex<EntryInner>>,
    conn: Box<dyn Connection>,
    tunnel: Option<Tunnel>,
    fault: &Arc<Notify>,
) {
    conn.attach_fault_notify(Arc::clone(fault));
    let arc: Arc<dyn Connection> = Arc::from(conn);
    if let Ok(mut g) = inner.lock() {
        g.connection = arc;
        g.tunnel = tunnel;
        g.audit_state = Arc::new(g.audit_state.new_connection_generation());
    }
}

fn set_health(inner: &Arc<Mutex<EntryInner>>, health: ConnectionHealth) {
    if let Ok(mut g) = inner.lock() {
        g.health = health;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use async_trait::async_trait;
    use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, ExecResult, QueryResult, TableInfo};

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_closed_tunnel_is_detected_within_one_poll_interval() {
        let closed = Arc::new(AtomicBool::new(false));
        let observed = closed.clone();
        let watcher = tokio::spawn(async move {
            wait_until_closed(|| Some(observed.load(Ordering::SeqCst))).await;
        });
        tokio::task::yield_now().await;
        closed.store(true, Ordering::SeqCst);
        tokio::time::advance(TUNNEL_POLL_INTERVAL).await;
        tokio::time::timeout(TUNNEL_POLL_INTERVAL, watcher)
            .await
            .expect("closed tunnel poll is bounded")
            .expect("watcher task completes");
    }

    #[test]
    fn reconnect_advances_audit_generation_without_clearing_global_lockdown() {
        let journal = Arc::new(AuditState::with_governed_writes_disabled());
        let old_state = Arc::new(journal.new_connection_generation());
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: Arc::new(IdleConn {
                attached: Arc::new(Mutex::new(None)),
                pings: Arc::new(AtomicUsize::new(0)),
            }) as Arc<dyn Connection>,
            tunnel: None,
            health: ConnectionHealth::Healthy,
            audit_state: old_state.clone(),
        }));

        swap_connection(
            &inner,
            Box::new(IdleConn {
                attached: Arc::new(Mutex::new(None)),
                pings: Arc::new(AtomicUsize::new(0)),
            }),
            None,
            &Arc::new(Notify::new()),
        );

        let new_state = inner.lock().unwrap().audit_state.clone();
        assert!(!Arc::ptr_eq(&old_state, &new_state));
        assert!(old_state.governed_writes_disabled());
        assert!(new_state.governed_writes_disabled());
    }

    struct CountingDriver {
        attempts: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl DatabaseDriver for CountingDriver {
        fn id(&self) -> &'static str {
            "counting"
        }

        fn display_name(&self) -> &'static str {
            "Counting"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            self.attempts.fetch_add(1, Ordering::SeqCst);
            Err(DriverError::ConnectionRefused)
        }
    }

    struct RejectingDriver {
        attempts: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl DatabaseDriver for RejectingDriver {
        fn id(&self) -> &'static str {
            "rejecting"
        }

        fn display_name(&self) -> &'static str {
            "Rejecting"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            self.attempts.fetch_add(1, Ordering::SeqCst);
            Err(DriverError::AuthFailed)
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_credential_failure_ends_the_retry_loop_and_reports_the_reason() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: Arc::new(IdleConn {
                attached: Arc::new(Mutex::new(None)),
                pings: Arc::new(AtomicUsize::new(0)),
            }) as Arc<dyn Connection>,
            tunnel: None,
            health: ConnectionHealth::Healthy,
            audit_state: Arc::new(AuditState::new()),
        }));
        let params = ReconnectParams {
            driver: Arc::new(RejectingDriver {
                attempts: attempts.clone(),
            }),
            opts: ConnectOptions::default(),
            ssh: None,
            environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
        };

        let outcome = reconnect_loop(&inner, &params, &CancellationToken::new(), &Arc::new(Notify::new())).await;

        assert!(outcome.is_err());
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "a wrong password must not be retried forever"
        );
        let health = inner.lock().expect("entry lock").health.clone();
        assert!(
            matches!(health, ConnectionHealth::Failed { ref reason } if reason.contains("password")),
            "{health:?}"
        );
    }

    struct IdleConn {
        attached: Arc<Mutex<Option<Arc<Notify>>>>,
        pings: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl Connection for IdleConn {
        async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
            Ok(vec![])
        }

        async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<tablepro_core::ColumnInfo>, DriverError> {
            Ok(vec![])
        }

        async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
            Err(DriverError::ConnectionRefused)
        }

        async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
            Err(DriverError::ConnectionRefused)
        }

        async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
            Err(DriverError::ConnectionRefused)
        }

        async fn execute_params(&self, _: &str, _: &[tablepro_core::Value]) -> Result<ExecResult, DriverError> {
            Err(DriverError::ConnectionRefused)
        }

        async fn execute_in_transaction(
            &self,
            _: &[(String, Vec<tablepro_core::Value>)],
        ) -> Result<Vec<u64>, DriverError> {
            Err(DriverError::ConnectionRefused)
        }

        async fn ping(&self) -> Result<(), DriverError> {
            self.pings.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }

        fn attach_fault_notify(&self, notify: Arc<Notify>) {
            *self.attached.lock().expect("fault lock") = Some(notify);
        }

        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    struct ReconnectingDriver {
        attempts: Arc<AtomicUsize>,
        attached: Arc<Mutex<Option<Arc<Notify>>>>,
        pings: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl DatabaseDriver for ReconnectingDriver {
        fn id(&self) -> &'static str {
            "reconnecting"
        }

        fn display_name(&self) -> &'static str {
            "Reconnecting"
        }

        fn default_port(&self) -> u16 {
            0
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            self.attempts.fetch_add(1, Ordering::SeqCst);
            Ok(Box::new(IdleConn {
                attached: self.attached.clone(),
                pings: self.pings.clone(),
            }))
        }
    }

    /// A reported fault must not wait for the ping interval, and must
    /// not be dismissed by a connection that still answers a ping.
    #[tokio::test(start_paused = true)]
    async fn a_reported_fault_starts_a_reconnect_before_the_next_ping() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: Arc::new(IdleConn {
                attached: Arc::new(Mutex::new(None)),
                pings: Arc::new(AtomicUsize::new(0)),
            }) as Arc<dyn Connection>,
            tunnel: None,
            health: ConnectionHealth::Healthy,
            audit_state: Arc::new(AuditState::new()),
        }));
        let params = ReconnectParams {
            driver: Arc::new(CountingDriver {
                attempts: attempts.clone(),
            }),
            opts: ConnectOptions::default(),
            ssh: None,
            environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
        };
        let cancel = CancellationToken::new();
        let fault = Arc::new(Notify::new());
        let monitor = tokio::spawn(run(inner.clone(), params, cancel.clone(), fault.clone()));

        fault.notify_one();
        tokio::time::sleep(BACKOFF_INITIAL + Duration::from_secs(1)).await;

        assert!(
            attempts.load(Ordering::SeqCst) >= 1,
            "the fault must trigger a reconnect"
        );
        assert!(matches!(
            inner.lock().expect("entry lock").health,
            ConnectionHealth::Reconnecting { .. }
        ));
        cancel.cancel();
        let _ = monitor.await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_reconnected_connection_reports_faults_before_its_next_ping() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let attached = Arc::new(Mutex::new(None));
        let pings = Arc::new(AtomicUsize::new(0));
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: Arc::new(IdleConn {
                attached: Arc::new(Mutex::new(None)),
                pings: pings.clone(),
            }) as Arc<dyn Connection>,
            tunnel: None,
            health: ConnectionHealth::Healthy,
            audit_state: Arc::new(AuditState::new()),
        }));
        let params = ReconnectParams {
            driver: Arc::new(ReconnectingDriver {
                attempts: attempts.clone(),
                attached: attached.clone(),
                pings: pings.clone(),
            }),
            opts: ConnectOptions::default(),
            ssh: None,
            environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
        };
        let cancel = CancellationToken::new();
        let fault = Arc::new(Notify::new());
        let monitor = tokio::spawn(run(inner.clone(), params, cancel.clone(), fault.clone()));
        tokio::task::yield_now().await;
        fault.notify_one();
        tokio::task::yield_now().await;
        tokio::time::advance(BACKOFF_INITIAL).await;
        for _ in 0..100 {
            if attempts.load(Ordering::SeqCst) >= 1 {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        let replacement_fault = attached
            .lock()
            .expect("fault lock")
            .clone()
            .expect("replacement connection receives fault notification");
        replacement_fault.notify_one();
        tokio::task::yield_now().await;
        tokio::time::advance(BACKOFF_INITIAL).await;
        for _ in 0..100 {
            if attempts.load(Ordering::SeqCst) >= 2 {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        assert_eq!(pings.load(Ordering::SeqCst), 0);

        assert!(matches!(
            inner.lock().expect("entry lock").health,
            ConnectionHealth::Healthy
        ));
        cancel.cancel();
        let _ = monitor.await;
    }

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
