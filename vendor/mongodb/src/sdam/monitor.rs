use std::{
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use crate::{bson::doc, sdam::topology::TopologyShutdown};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::{
    description::server::{ServerDescription, TopologyVersion},
    topology::{SdamEventEmitter, TopologyCheckRequestReceiver},
    TopologyUpdater,
    TopologyWatcher,
};
use crate::{
    client::options::ServerMonitoringMode,
    cmap::{establish::ConnectionEstablisher, Connection},
    error::{Error, Result},
    event::sdam::{
        SdamEvent,
        ServerHeartbeatFailedEvent,
        ServerHeartbeatStartedEvent,
        ServerHeartbeatSucceededEvent,
    },
    hello::{hello_command, run_hello, AwaitableHelloOptions, HelloReply},
    options::{ClientOptions, ServerAddress},
    runtime::{self, WorkerHandle, WorkerHandleListener},
};

fn next_monitoring_connection_id() -> u32 {
    static MONITORING_CONNECTION_ID: AtomicU32 = AtomicU32::new(0);

    MONITORING_CONNECTION_ID.fetch_add(1, Ordering::SeqCst)
}

pub(crate) const DEFAULT_HEARTBEAT_FREQUENCY: Duration = Duration::from_secs(10);
pub(crate) const MIN_HEARTBEAT_FREQUENCY: Duration = Duration::from_millis(500);

/// Monitor that performs regular heartbeats to determine server status.
pub(crate) struct Monitor {
    address: ServerAddress,
    connection: Option<Connection>,
    connection_establisher: ConnectionEstablisher,
    topology_updater: TopologyUpdater,
    topology_watcher: TopologyWatcher,
    sdam_event_emitter: Option<SdamEventEmitter>,
    client_options: ClientOptions,

    /// Whether this monitor is allowed to use the streaming protocol.
    allow_streaming: bool,

    /// The most recent topology version returned by the server in a hello response.
    topology_version: Option<TopologyVersion>,

    /// The RTT monitor; once it's started this is None.
    pending_rtt_monitor: Option<RttMonitor>,

    /// Handle to the RTT monitor, used to get the latest known round trip time for a given server
    /// and to reset the RTT when the monitor disconnects from the server.
    rtt_monitor_handle: RttMonitorHandle,

    /// Handle to the `Server` instance in the `Topology`. This is used to detect when a server has
    /// been removed from the topology and no longer needs to be monitored and to receive
    /// cancellation requests.
    request_receiver: MonitorRequestReceiver,

    shutdown: TopologyShutdown,
}

impl Monitor {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn start(
        address: ServerAddress,
        topology_updater: TopologyUpdater,
        topology_watcher: TopologyWatcher,
        sdam_event_emitter: Option<SdamEventEmitter>,
        manager_receiver: MonitorRequestReceiver,
        client_options: ClientOptions,
        connection_establisher: ConnectionEstablisher,
        shutdown: TopologyShutdown,
    ) {
        let (rtt_monitor, rtt_monitor_handle) = RttMonitor::new(
            address.clone(),
            topology_watcher.clone(),
            connection_establisher.clone(),
            client_options.clone(),
            shutdown.clone(),
        );
        let allow_streaming = match client_options
            .server_monitoring_mode
            .clone()
            .unwrap_or(ServerMonitoringMode::Auto)
        {
            ServerMonitoringMode::Stream => true,
            ServerMonitoringMode::Poll => false,
            ServerMonitoringMode::Auto => !crate::cmap::is_faas(),
        };
        let monitor = Self {
            address,
            client_options,
            connection_establisher,
            topology_updater,
            topology_watcher,
            sdam_event_emitter,
            pending_rtt_monitor: Some(rtt_monitor),
            rtt_monitor_handle,
            request_receiver: manager_receiver,
            connection: None,
            allow_streaming,
            topology_version: None,
            shutdown: shutdown.clone(),
        };

        runtime::spawn(shutdown.tasks.track_future(monitor.execute()));
    }

    async fn execute(mut self) {
        let heartbeat_frequency = self.heartbeat_frequency();

        while self.is_alive() {
            let check_succeeded = self.check_server().await;

            if self.topology_version.is_some() && self.allow_streaming {
                if let Some(rtt_monitor) = self.pending_rtt_monitor.take() {
                    runtime::spawn(
                        self.shutdown
                            .tasks
                            .clone()
                            .track_future(rtt_monitor.execute()),
                    );
                }
            }

            // In the streaming protocol, we read from the socket continuously
            // rather than polling at specific intervals, unless the most recent check
            // failed.
            //
            // We only go to sleep when using the polling protocol (i.e. server never returned a
            // topologyVersion) or when the most recent check failed.
            if self.topology_version.is_none() || !check_succeeded || !self.allow_streaming {
                self.request_receiver
                    .wait_for_check_request(
                        self.client_options.min_heartbeat_frequency(),
                        heartbeat_frequency,
                        self.shutdown.token.clone(),
                    )
                    .await;
            }
        }
    }

    fn is_alive(&self) -> bool {
        self.request_receiver.is_alive()
    }

    /// Checks the the server by running a hello command. If an I/O error occurs, the
    /// connection will replaced with a new one.
    ///
    /// Returns whether the check succeeded or not.
    async fn check_server(&mut self) -> bool {
        let check_result = match self.perform_hello().await {
            HelloResult::Err(e) => {
                let previous_description = self.topology_watcher.server_description(&self.address);
                if e.is_network_error()
                    && previous_description
                        .map(|sd| sd.is_available())
                        .unwrap_or(false)
                {
                    self.handle_error(e).await;
                    self.perform_hello().await
                } else {
                    HelloResult::Err(e)
                }
            }
            other => other,
        };

        match check_result {
            HelloResult::Ok(reply) => {
                let avg_rtt = self.rtt_monitor_handle.average_rtt();

                // If we have an Ok result, then we at least performed a handshake, which should
                // mean that the RTT has a value.
                debug_assert!(avg_rtt.is_some());

                // In the event that we don't have an average RTT value (e.g. due to a bug), just
                // default to using the maximum possible value.
                let avg_rtt = avg_rtt.unwrap_or(Duration::MAX);

                let server_description =
                    ServerDescription::new_from_hello_reply(self.address.clone(), reply, avg_rtt);
                self.topology_updater.update(server_description).await;
                true
            }
            HelloResult::Err(e) => {
                self.handle_error(e).await;
                false
            }
            HelloResult::Cancelled { .. } => false,
        }
    }

    async fn perform_hello(&mut self) -> HelloResult {
        let driver_connection_id = self
            .connection
            .as_ref()
            .map(|c| c.id)
            .unwrap_or(next_monitoring_connection_id());

        self.emit_event(|| {
            SdamEvent::ServerHeartbeatStarted(ServerHeartbeatStartedEvent {
                server_address: self.address.clone(),
                awaited: self.topology_version.is_some() && self.allow_streaming,
                driver_connection_id,
                server_connection_id: self.connection.as_ref().and_then(|c| c.server_id),
            })
        });

        let heartbeat_frequency = self.heartbeat_frequency();
        let timeout = if self.topology_version.is_some() {
            // For streaming responses, use connectTimeoutMS + heartbeatFrequencyMS for socket
            // timeout.
            heartbeat_frequency
                .checked_add(self.client_options.connect_timeout())
                .unwrap_or(Duration::MAX)
        } else {
            // Otherwise, just use connectTimeoutMS.
            self.client_options.connect_timeout()
        };

        let execute_hello = async {
            match self.connection {
                Some(ref mut conn) => {
                    // If the server indicated there was moreToCome, just read from the socket.
                    if conn.is_streaming() {
                        conn.receive_message()
                            .await
                            .and_then(|r| r.into_hello_reply())
                    // Otherwise, send a regular hello command.
                    } else {
                        // If the initial handshake returned a topology version, send it back to the
                        // server to begin streaming responses.
                        let opts = if self.allow_streaming {
                            self.topology_version.map(|tv| AwaitableHelloOptions {
                                topology_version: tv,
                                max_await_time: heartbeat_frequency,
                            })
                        } else {
                            None
                        };

                        let command = hello_command(
                            self.client_options.server_api.as_ref(),
                            self.client_options.load_balanced,
                            Some(conn.stream_description()?.hello_ok),
                            opts,
                        );

                        run_hello(conn, command, None).await
                    }
                }
                None => {
                    let start = Instant::now();
                    let res = self
                        .connection_establisher
                        .establish_monitoring_connection(self.address.clone(), driver_connection_id)
                        .await;
                    match res {
                        Ok((conn, hello_reply)) => {
                            self.rtt_monitor_handle.add_sample(start.elapsed());
                            self.connection = Some(conn);
                            Ok(hello_reply)
                        }
                        Err(e) => Err(e),
                    }
                }
            }
        };

        // Execute the hello while also listening for cancellation and keeping track of the timeout.
        let start = Instant::now();
        let result = tokio::select! {
            result = execute_hello => match result {
                Ok(mut reply) => {
                    // Do not propagate server reported cluster time for monitoring hello responses.
                    reply.cluster_time = None;
                    HelloResult::Ok(reply)
                },
                Err(e) => HelloResult::Err(e)
            },
            r = self.request_receiver.wait_for_cancellation() => {
                let reason_error = match r {
                    CancellationReason::Error(e) => e,
                    CancellationReason::ServerClosed => Error::internal("server closed")
                };
                HelloResult::Cancelled { reason: reason_error }
            }
            _ = tokio::time::sleep(timeout) => {
                HelloResult::Err(Error::network_timeout())
            }
        };
        let duration = start.elapsed();

        let awaited = self.topology_version.is_some() && self.allow_streaming;
        match result {
            HelloResult::Ok(ref r) => {
                if !awaited {
                    self.rtt_monitor_handle.add_sample(duration);
                }
                self.emit_event(|| {
                    let mut reply =
                        crate::bson::Document::try_from(r.raw_command_response.as_ref())
                            .unwrap_or_else(|e| doc! { "deserialization error": e.to_string() });
                    // if this hello call is part of a handshake, remove speculative authentication
                    // information before publishing an event
                    reply.remove("speculativeAuthenticate");
                    SdamEvent::ServerHeartbeatSucceeded(ServerHeartbeatSucceededEvent {
                        duration,
                        reply,
                        server_address: self.address.clone(),
                        awaited,
                        driver_connection_id,
                        server_connection_id: self.connection.as_ref().and_then(|c| c.server_id),
                    })
                });

                // If the response included a topology version, cache it so that we can return it in
                // the next hello.
                self.topology_version = r.command_response.topology_version;
            }
            HelloResult::Err(ref e) | HelloResult::Cancelled { reason: ref e } => {
                self.emit_event(|| {
                    SdamEvent::ServerHeartbeatFailed(ServerHeartbeatFailedEvent {
                        duration,
                        failure: e.clone(),
                        server_address: self.address.clone(),
                        awaited,
                        driver_connection_id,
                        server_connection_id: self.connection.as_ref().and_then(|c| c.server_id),
                    })
                });

                // Per the spec, cancelled requests and errors both require the monitoring
                // connection to be closed.
                self.connection = None;
                self.rtt_monitor_handle.reset_average_rtt();
                self.topology_version.take();
            }
        }

        result
    }

    async fn handle_error(&mut self, error: Error) -> bool {
        self.topology_updater
            .handle_monitor_error(self.address.clone(), error)
            .await
    }

    fn emit_event<F>(&self, event: F)
    where
        F: FnOnce() -> SdamEvent,
    {
        if let Some(ref emitter) = self.sdam_event_emitter {
            // We don't care about ordering or waiting for the event to have been received.
            #[allow(clippy::let_underscore_future)]
            let _ = emitter.emit(event());
        }
    }

    fn heartbeat_frequency(&self) -> Duration {
        self.client_options
            .heartbeat_freq
            .unwrap_or(DEFAULT_HEARTBEAT_FREQUENCY)
    }
}

/// The monitor used for tracking the round-trip-time to the server, as described in the SDAM spec.
/// This monitor uses its own connection to make RTT measurements, and it publishes the averages of
/// those measurements to a channel.
struct RttMonitor {
    sender: Arc<watch::Sender<RttInfo>>,
    connection: Option<Connection>,
    topology: TopologyWatcher,
    address: ServerAddress,
    client_options: ClientOptions,
    connection_establisher: ConnectionEstablisher,
    shutdown: TopologyShutdown,
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct RttInfo {
    pub(crate) average: Option<Duration>,
}

impl RttInfo {
    pub(crate) fn add_sample(&mut self, sample: Duration) {
        match self.average {
            Some(old_rtt) => {
                // Average is 20% most recent sample and 80% prior sample.
                self.average = Some((sample / 5) + (old_rtt * 4 / 5))
            }
            None => self.average = Some(sample),
        }
    }
}

impl RttMonitor {
    /// Creates a new RTT monitor for the server at the given address, returning a receiver that the
    /// RTT statistics will be published to. This does not start the monitor.
    /// [`RttMonitor::execute`] needs to be invoked to start it.
    fn new(
        address: ServerAddress,
        topology: TopologyWatcher,
        connection_establisher: ConnectionEstablisher,
        client_options: ClientOptions,
        shutdown: TopologyShutdown,
    ) -> (Self, RttMonitorHandle) {
        let (sender, rtt_receiver) = watch::channel(RttInfo { average: None });
        let sender = Arc::new(sender);

        let monitor = Self {
            address,
            connection: None,
            topology,
            client_options,
            connection_establisher,
            sender: sender.clone(),
            shutdown,
        };

        let handle = RttMonitorHandle {
            reset_sender: sender,
            rtt_receiver,
        };
        (monitor, handle)
    }

    async fn execute(mut self) {
        // keep executing until either the topology is closed or server monitor is done (i.e. the
        // sender is closed)
        while self.topology.is_alive() && !self.sender.is_closed() {
            let timeout = self.client_options.connect_timeout();

            let perform_check = async {
                match self.connection {
                    Some(ref mut conn) => {
                        let command = hello_command(
                            self.client_options.server_api.as_ref(),
                            self.client_options.load_balanced,
                            Some(conn.stream_description()?.hello_ok),
                            None,
                        );
                        conn.send_message(command).await?;
                    }
                    None => {
                        let connection = self
                            .connection_establisher
                            .establish_monitoring_connection(
                                self.address.clone(),
                                next_monitoring_connection_id(),
                            )
                            .await?
                            .0;
                        self.connection = Some(connection);
                    }
                };
                Result::Ok(())
            };

            let start = Instant::now();
            let check_succeded = tokio::select! {
                r = perform_check => r.is_ok(),
                _ = tokio::time::sleep(timeout) => {
                    false
                }
            };

            if check_succeded {
                self.sender
                    .send_modify(|rtt_info| rtt_info.add_sample(start.elapsed()));
            } else {
                // From the SDAM spec: "Errors encountered when running a hello or legacy hello
                // command MUST NOT update the topology."
                self.connection = None;

                // Also from the SDAM spec: "Don't call reset() here. The Monitor thread is
                // responsible for resetting the average RTT."
            }

            let sleep = tokio::time::sleep(
                self.client_options
                    .heartbeat_freq
                    .unwrap_or(DEFAULT_HEARTBEAT_FREQUENCY),
            );
            tokio::select! {
                _ = self.shutdown.token.cancelled() => (),
                _ = sleep => (),
            }
        }
    }
}

struct RttMonitorHandle {
    rtt_receiver: watch::Receiver<RttInfo>,
    reset_sender: Arc<watch::Sender<RttInfo>>,
}

impl RttMonitorHandle {
    fn average_rtt(&self) -> Option<Duration> {
        self.rtt_receiver.borrow().average
    }

    fn reset_average_rtt(&mut self) {
        let _ = self.reset_sender.send(RttInfo::default());
    }

    fn add_sample(&mut self, sample: Duration) {
        self.reset_sender.send_modify(|rtt_info| {
            rtt_info.add_sample(sample);
        });
    }
}

#[allow(clippy::large_enum_variant)] // The Ok branch is bigger but more common
#[derive(Debug, Clone)]
enum HelloResult {
    Ok(HelloReply),
    Err(Error),
    Cancelled { reason: Error },
}

/// Struct used to keep a monitor alive, individually request an immediate check, and to cancel
/// in-progress checks.
#[derive(Debug, Clone)]
pub(crate) struct MonitorManager {
    /// `WorkerHandle` used to keep the monitor alive. When this is dropped, the monitor will exit.
    handle: WorkerHandle,

    /// Sender used to cancel in-progress monitor checks and, if the reason is TopologyClosed,
    /// close the monitor.
    cancellation_sender: Arc<watch::Sender<CancellationReason>>,

    /// Sender used to individually request an immediate check from the monitor associated with
    /// this manager.
    check_requester: Arc<watch::Sender<()>>,
}

impl MonitorManager {
    pub(crate) fn new(monitor_handle: WorkerHandle) -> Self {
        // The CancellationReason used as the initial value is just a placeholder. The only receiver
        // that could have seen it is dropped in this scope, and the monitor's receiver will
        // never observe it.
        let (tx, _) = watch::channel(CancellationReason::ServerClosed);
        let check_requester = Arc::new(watch::channel(()).0);

        MonitorManager {
            handle: monitor_handle,
            cancellation_sender: Arc::new(tx),
            check_requester,
        }
    }

    /// Cancel any in progress checks, notify the monitor that it should close, and wait for it to
    /// do so.
    pub(crate) async fn close_monitor(self) {
        drop(self.handle);
        let _ = self
            .cancellation_sender
            .send(CancellationReason::ServerClosed);
        self.cancellation_sender.closed().await;
    }

    /// Cancel any in progress check with the provided reason.
    pub(crate) fn cancel_in_progress_check(&mut self, reason: impl Into<CancellationReason>) {
        let _ = self.cancellation_sender.send(reason.into());
    }

    /// Request an immediate topology check by this monitor. If the monitor is currently performing
    /// a check, this request will be ignored.
    pub(crate) fn request_immediate_check(&mut self) {
        let _ = self.check_requester.send(());
    }
}

/// Struct used to receive cancellation and immediate check requests from various different places.
pub(crate) struct MonitorRequestReceiver {
    /// Handle listener used to determine whether this monitor should continue to execute or not.
    /// The `MonitorManager` owned by the `TopologyWorker` owns the handle that this listener
    /// corresponds to.
    handle_listener: WorkerHandleListener,

    /// Receiver for cancellation requests. These come in when an operation encounters network
    /// errors or when the topology is closed.
    cancellation_receiver: watch::Receiver<CancellationReason>,

    /// Receiver used to listen for immediate check requests sent by the `TopologyWorker` that only
    /// apply to the server associated with the monitor, not for the whole topology.
    individual_check_request_receiver: watch::Receiver<()>,

    /// Receiver used to listen for immediate check requests that were broadcast to the entire
    /// topology by operations attempting to select a server.
    topology_check_request_receiver: TopologyCheckRequestReceiver,
}

#[derive(Debug, Clone)]
pub(crate) enum CancellationReason {
    Error(Error),
    ServerClosed,
}

impl From<Error> for CancellationReason {
    fn from(e: Error) -> Self {
        Self::Error(e)
    }
}

impl MonitorRequestReceiver {
    pub(crate) fn new(
        manager: &MonitorManager,
        topology_check_request_receiver: TopologyCheckRequestReceiver,
        handle_listener: WorkerHandleListener,
    ) -> Self {
        Self {
            handle_listener,
            cancellation_receiver: manager.cancellation_sender.subscribe(),
            individual_check_request_receiver: manager.check_requester.subscribe(),
            topology_check_request_receiver,
        }
    }

    /// Wait for a request to cancel the current in-progress check to come in, returning the reason
    /// for it. Any check requests that are received during this time will be ignored, as per
    /// the spec.
    async fn wait_for_cancellation(&mut self) -> CancellationReason {
        let err = if self.cancellation_receiver.changed().await.is_ok() {
            self.cancellation_receiver.borrow().clone()
        } else {
            CancellationReason::ServerClosed
        };
        // clear out ignored check requests
        self.individual_check_request_receiver.borrow_and_update();
        err
    }

    /// Wait for a request to immediately check the server to be received, guarded by the provided
    /// timeout. If the server associated with this monitor is removed from the topology, this
    /// method will return.
    ///
    /// The `delay` parameter indicates how long this method should wait before listening to
    /// requests. The time spent in the delay counts toward the provided timeout.
    async fn wait_for_check_request(
        &mut self,
        delay: Duration,
        timeout: Duration,
        cancel: CancellationToken,
    ) {
        let _ = runtime::timeout(timeout, async {
            let wait_for_check_request = async {
                tokio::time::sleep(delay).await;
                self.topology_check_request_receiver
                    .wait_for_check_request()
                    .await;
            };
            tokio::pin!(wait_for_check_request);

            tokio::select! {
                _ = cancel.cancelled() => (),
                _ = self.individual_check_request_receiver.changed() => (),
                _ = &mut wait_for_check_request => (),
                // Don't continue waiting after server has been removed from the topology.
                _ = self.handle_listener.wait_for_all_handle_drops() => (),
            }
        })
        .await;

        // clear out ignored cancellation requests while we were waiting to begin a check
        self.cancellation_receiver.borrow_and_update();
    }

    fn is_alive(&self) -> bool {
        self.handle_listener.is_alive()
    }
}
