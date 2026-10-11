use std::{
    collections::{HashMap, HashSet},
    future::Future,
    sync::{Arc, Weak},
    time::Duration,
};

use futures_util::{
    stream::{FuturesUnordered, StreamExt},
    FutureExt,
};
use tokio::sync::{
    mpsc::{self, UnboundedReceiver, UnboundedSender},
    watch::{self, Ref},
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};

use crate::{
    bson::oid::ObjectId,
    client::options::{ClientOptions, ServerAddress},
    cmap::{
        conn::{pooled::PooledConnection, ConnectionGeneration},
        establish::{handshake::ClientMetadata, ConnectionEstablisher, EstablisherOptions},
        Command,
        PoolGeneration,
    },
    error::{load_balanced_mode_mismatch, Error, Redact, Result, SYSTEM_OVERLOADED_ERROR},
    event::sdam::{
        SdamEvent,
        ServerClosedEvent,
        ServerDescriptionChangedEvent,
        ServerOpeningEvent,
        TopologyClosedEvent,
        TopologyDescriptionChangedEvent,
        TopologyOpeningEvent,
    },
    runtime::{self, AcknowledgedMessage, WorkerHandle, WorkerHandleListener},
    selection_criteria::SelectionCriteria,
    ClusterTime,
    ServerInfo,
    ServerType,
    TopologyType,
};

#[cfg(feature = "tracing-unstable")]
use crate::trace::topology::TopologyTracingEventEmitter;

use super::{
    monitor::{MonitorManager, MonitorRequestReceiver},
    srv_polling::SrvPollingMonitor,
    Monitor,
    Server,
    ServerDescription,
    TopologyDescription,
    TransactionSupportStatus,
};

/// A struct providing access to the client's current view of the topology.
/// When this is dropped, monitors will stop performing checks.
#[derive(Debug)]
pub(crate) struct Topology {
    #[cfg(any(feature = "tracing-unstable", test))]
    pub(crate) id: ObjectId,
    watcher: TopologyWatcher,
    updater: TopologyUpdater,
    pub(crate) metadata: Arc<std::sync::RwLock<ClientMetadata>>,
    shutdown: TopologyShutdown,
    _worker_handle: WorkerHandle,
}

#[derive(Debug, Clone)]
pub(crate) struct TopologyShutdown {
    pub(crate) token: CancellationToken,
    pub(crate) tasks: TaskTracker,
}

impl TopologyShutdown {
    pub(crate) fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            tasks: TaskTracker::new(),
        }
    }
}

impl Topology {
    pub(crate) fn new(options: ClientOptions) -> Result<Topology> {
        let description = TopologyDescription::default();
        let id = ObjectId::new();

        let event_emitter =
            if options.sdam_event_handler.is_some() || cfg!(feature = "tracing-unstable") {
                let user_handler = options.sdam_event_handler.clone();

                #[cfg(feature = "tracing-unstable")]
                let tracing_emitter =
                    TopologyTracingEventEmitter::new(options.tracing_max_document_length_bytes, id);
                let (tx, mut rx) = mpsc::unbounded_channel::<AcknowledgedMessage<SdamEvent>>();
                runtime::spawn(async move {
                    while let Some(event) = rx.recv().await {
                        let (event, ack) = event.into_parts();

                        if let Some(ref user_handler) = user_handler {
                            #[cfg(feature = "tracing-unstable")]
                            user_handler.handle(event.clone());
                            #[cfg(not(feature = "tracing-unstable"))]
                            user_handler.handle(event);
                        }
                        #[cfg(feature = "tracing-unstable")]
                        tracing_emitter.handle(event);

                        ack.acknowledge(());
                    }
                });
                Some(SdamEventEmitter { sender: tx })
            } else {
                None
            };

        let (updater, update_receiver) = TopologyUpdater::channel();
        let (worker_handle, handle_listener) = WorkerHandleListener::channel();
        let state = TopologyState {
            description: description.clone(),
            servers: Default::default(),
        };
        let (watcher, publisher) = TopologyWatcher::channel(state);

        let spec = TopologySpec::try_from(options)?;
        let connection_establisher = ConnectionEstablisher::new(EstablisherOptions::from(&spec))?;

        let shutdown = TopologyShutdown::new();

        let worker = TopologyWorker {
            id,
            topology_description: description,
            servers: Default::default(),
            update_receiver,
            publisher,
            options: spec.options,
            topology_watcher: watcher.clone(),
            topology_updater: updater.clone(),
            handle_listener,
            event_emitter,
            connection_establisher,
            shutdown: shutdown.clone(),
        };

        worker.start();

        Ok(Topology {
            #[cfg(any(feature = "tracing-unstable", test))]
            id,
            watcher,
            updater,
            metadata: spec.metadata,
            shutdown,
            _worker_handle: worker_handle,
        })
    }

    pub(crate) fn updater(&self) -> &TopologyUpdater {
        &self.updater
    }

    pub(crate) fn watcher(&self) -> &TopologyWatcher {
        &self.watcher
    }

    pub(crate) fn latest(&self) -> Ref<'_, TopologyState> {
        self.watcher.peek_latest()
    }

    pub(crate) async fn shutdown(&self) {
        self.shutdown.token.cancel();
        self.shutdown.tasks.close();
        self.shutdown.tasks.wait().await;
    }
}

pub(crate) struct TopologySpec {
    pub(crate) options: ClientOptions,
    pub(crate) metadata: Arc<std::sync::RwLock<ClientMetadata>>,
}

impl TryFrom<ClientOptions> for TopologySpec {
    type Error = Error;
    fn try_from(options: ClientOptions) -> Result<Self> {
        let metadata = Arc::new(std::sync::RwLock::new(ClientMetadata::try_from(&options)?));
        Ok(Self { options, metadata })
    }
}

#[derive(Debug, Clone)]
pub(crate) struct TopologyState {
    pub(crate) description: TopologyDescription,
    servers: HashMap<ServerAddress, Weak<Server>>,
}

impl TopologyState {
    /// Get a HashMap of strong references to the underlying servers in the state, filtering out any
    /// servers that are no longer part of the current topology.
    pub(crate) fn servers(&self) -> HashMap<ServerAddress, Arc<Server>> {
        let mut out = HashMap::new();
        for (k, v) in self.servers.iter() {
            if let Some(server) = v.upgrade() {
                out.insert(k.clone(), server);
            }
        }
        out
    }
}

#[derive(Debug)]
pub(crate) enum UpdateMessage {
    AdvanceClusterTime(ClusterTime),
    ServerUpdate(Box<ServerDescription>),
    SyncHosts(HashSet<ServerAddress>),
    MonitorError {
        address: ServerAddress,
        error: Error,
    },
    ApplicationError {
        address: ServerAddress,
        error: Error,
        phase: HandshakePhase,
    },
    Broadcast(BroadcastMessage),
}

#[derive(Debug, Clone)]
pub(crate) enum BroadcastMessage {
    FillPool,
    #[cfg(test)]
    SyncWorkers,
}

/// Struct modeling the worker task that owns the actual topology state and processes updates to it.
struct TopologyWorker {
    /// Unique ID for the topology.
    id: ObjectId,

    /// Receiver used to listen for updates to the topology from monitors or operation execution.
    update_receiver: TopologyUpdateReceiver,

    /// Listener used to determine when to stop this worker.
    handle_listener: WorkerHandleListener,

    /// Channel used to publish new topology information (e.g. so that operations can perform
    /// server selection)
    publisher: TopologyPublisher,

    /// Map of addresses to servers in the topology. Once servers are dropped from this map, they
    /// will cease to be monitored and their connection pools will be closed.
    servers: HashMap<ServerAddress, MonitoredServer>,

    /// The current TopologyDescription.
    topology_description: TopologyDescription,

    connection_establisher: ConnectionEstablisher,

    event_emitter: Option<SdamEventEmitter>,
    options: ClientOptions,

    // the following fields stored here for creating new server monitors
    topology_watcher: TopologyWatcher,
    topology_updater: TopologyUpdater,
    shutdown: TopologyShutdown,
}

impl TopologyWorker {
    /// Open the topology by populating it with the initial seed list provided in the options.
    /// This will kick off the monitoring tasks for the servers included in the seedlist, as well as
    /// the SRV polling monitor.
    async fn initialize(&mut self) {
        self.emit_event(|| {
            SdamEvent::TopologyOpening(TopologyOpeningEvent {
                topology_id: self.id,
            })
        });

        let mut new_description = self.topology_description.clone();

        new_description.initialize(&self.options);

        self.update_topology(new_description).await;

        if self.options.load_balanced == Some(true) {
            let base = ServerDescription::new(&self.options.hosts[0]);
            self.update_server(ServerDescription {
                server_type: ServerType::LoadBalancer,
                average_round_trip_time: None,
                ..base
            })
            .await;
        }

        if self.monitoring_enabled() {
            SrvPollingMonitor::start(
                self.topology_updater.clone(),
                self.topology_watcher.clone(),
                self.options.clone(),
                self.shutdown.clone(),
            );
        }

        #[cfg(test)]
        let _ = self.publisher.initialized_sender.send(true);
    }

    fn start(mut self) {
        runtime::spawn(self.shutdown.tasks.clone().track_future(async move {
            self.initialize().await;

            loop {
                tokio::select! {
                    _ = self.shutdown.token.cancelled() => break,
                    Some(update) = self.update_receiver.recv() => {
                        let (update, ack) = update.into_parts();
                        let ack = Some(ack);
                        let changed = match update {
                            UpdateMessage::AdvanceClusterTime(to) => {
                                self.advance_cluster_time(to);
                                true
                            }
                            UpdateMessage::SyncHosts(hosts) => {
                                self.sync_hosts(hosts).await
                            }
                            UpdateMessage::ServerUpdate(sd) => {
                                self.update_server(*sd).await
                            }
                            UpdateMessage::MonitorError { address, error } => {
                                self.handle_monitor_error(address, error).await
                            }
                            UpdateMessage::ApplicationError {
                                address,
                                error,
                                phase,
                            } => self.handle_application_error(address, error, phase).await,
                            UpdateMessage::Broadcast(msg) => {
                                let rxen: FuturesUnordered<_> = self
                                    .servers
                                    .values()
                                    .map(|v| v.pool.broadcast(msg.clone()))
                                    .collect();
                                let _: Vec<_> = rxen.collect().await;
                                false
                            }
                        };
                        if let Some(ack) = ack {
                            ack.acknowledge(changed);
                        }
                    },
                    _ = self.handle_listener.wait_for_all_handle_drops() => {
                        break
                    }
                }
            }

            // indicate to the topology watchers that the topology is no longer alive
            drop(self.publisher);

            // Drop the update receiver so monitors' topology_updater.update() calls fail
            // immediately instead of waiting for acknowledgment from this (now-exited) loop.
            // Without this, close_monitor().await deadlocks: we wait for the monitor to exit, but
            // the monitor waits for us to acknowledge its update.
            drop(self.update_receiver);

            #[cfg(test)]
            if let Some(dur) = self
                .options
                .test_options
                .as_ref()
                .and_then(|to| to.topology_worker_shutdown_delay)
            {
                // In tests, sleep briefly to give any in-flight monitor hello responses a chance to
                // complete and call topology_updater.update(). This widens the race window to
                // verify the deadlock fix (dropping update_receiver before closing monitors). Sleep
                // longer than heartbeat_freq (maxAwaitTimeMS) to ensure the monitor completes a
                // hello and calls topology_updater.update() during this window. Without the fix
                // above, this would deadlock.
                tokio::time::sleep(dur).await;
            }

            // Close all the monitors.
            let mut close_futures = FuturesUnordered::new();
            for (address, server) in self.servers.into_iter() {
                if let Some(ref emitter) = self.event_emitter {
                    emitter
                        .emit(SdamEvent::ServerClosed(ServerClosedEvent {
                            address,
                            topology_id: self.id,
                        }))
                        .await;
                }
                drop(server.inner);
                close_futures.push(server.monitor_manager.close_monitor());
            }
            while close_futures.next().await.is_some() {}

            if let Some(emitter) = self.event_emitter {
                if !self.topology_description.servers.is_empty() {
                    let previous_description = self.topology_description;
                    let mut new_description = previous_description.clone();
                    new_description.servers.clear();
                    new_description.topology_type = TopologyType::Unknown;

                    emitter
                        .emit(SdamEvent::TopologyDescriptionChanged(Box::new(
                            TopologyDescriptionChangedEvent {
                                topology_id: self.id,
                                previous_description: previous_description.into(),
                                new_description: new_description.into(),
                            },
                        )))
                        .await;
                }

                emitter
                    .emit(SdamEvent::TopologyClosed(TopologyClosedEvent {
                        topology_id: self.id,
                    }))
                    .await;
            }
        }));
    }

    /// Publish the current TopologyDescription and map of Servers.
    fn publish_state(&self) {
        let servers = self
            .servers
            .iter()
            .map(|(k, v)| (k.clone(), Arc::downgrade(&v.inner)))
            .collect();
        self.publisher.publish_new_state(TopologyState {
            description: self.topology_description.clone(),
            servers,
        })
    }

    fn advance_cluster_time(&mut self, to: ClusterTime) {
        self.topology_description.advance_cluster_time(&to);
        self.publish_state()
    }

    async fn sync_hosts(&mut self, hosts: HashSet<ServerAddress>) -> bool {
        let mut new_description = self.topology_description.clone();
        new_description.sync_hosts(hosts);
        self.update_topology(new_description).await
    }

    /// Update the topology using the provided `ServerDescription`.
    async fn update_server(&mut self, sd: ServerDescription) -> bool {
        // TODO: RUST-1270 change this method to not return a result.
        let mut new_description = self.topology_description.clone();
        let _ = new_description.update(sd);
        self.update_topology(new_description).await
    }

    /// Emit the appropriate SDAM monitoring events given the changes to the
    /// topology as the result of an update, if any.
    async fn update_topology(&mut self, new_topology_description: TopologyDescription) -> bool {
        let old_description =
            std::mem::replace(&mut self.topology_description, new_topology_description);
        let diff = old_description.diff(&self.topology_description);
        let changed = diff.is_some();
        if let Some(diff) = diff {
            #[cfg(not(test))]
            let changed_servers = diff.changed_servers;

            // For ordering of events in tests, sort the addresses.
            #[cfg(test)]
            let changed_servers = {
                let mut servers = diff.changed_servers.into_iter().collect::<Vec<_>>();
                servers.sort_by_key(|(addr, _)| match addr {
                    ServerAddress::Tcp { host, port } => (host, port),
                    #[cfg(unix)]
                    ServerAddress::Unix { .. } => unreachable!(),
                });
                servers
            };

            for (address, (previous_description, new_description)) in changed_servers {
                if new_description.server_type.is_data_bearing()
                    || (new_description.server_type != ServerType::Unknown
                        && self.topology_description.topology_type() == TopologyType::Single)
                {
                    if let Some(s) = self.servers.get(address) {
                        s.pool.mark_as_ready().await;
                    }
                }
                self.emit_event(|| {
                    SdamEvent::ServerDescriptionChanged(Box::new(ServerDescriptionChangedEvent {
                        address: address.clone(),
                        topology_id: self.id,
                        previous_description: ServerInfo::new_owned(previous_description.clone()),
                        new_description: ServerInfo::new_owned(new_description.clone()),
                    }))
                });
            }

            #[cfg(not(test))]
            let removed_addresses = diff.removed_addresses;

            #[cfg(test)]
            let removed_addresses = {
                let mut addresses = diff.removed_addresses.into_iter().collect::<Vec<_>>();
                addresses.sort_by_key(|addr| match addr {
                    ServerAddress::Tcp { host, port } => (host, port),
                    #[cfg(unix)]
                    ServerAddress::Unix { .. } => unreachable!(),
                });
                addresses
            };

            for address in removed_addresses {
                let removed_server = self.servers.remove(address);
                debug_assert!(
                    removed_server.is_some(),
                    "tried to remove non-existent address from topology: {}",
                    Redact(address)
                );

                self.emit_event(|| {
                    SdamEvent::ServerClosed(ServerClosedEvent {
                        address: address.clone(),
                        topology_id: self.id,
                    })
                });
            }

            self.emit_event(|| {
                SdamEvent::TopologyDescriptionChanged(Box::new(TopologyDescriptionChangedEvent {
                    topology_id: self.id,
                    previous_description: old_description.clone().into(),
                    new_description: self.topology_description.clone().into(),
                }))
            });

            #[cfg(not(test))]
            let added_addresses = diff.added_addresses;

            #[cfg(test)]
            let added_addresses = {
                let mut addresses = diff.added_addresses.into_iter().collect::<Vec<_>>();
                addresses.sort_by_key(|addr| match addr {
                    ServerAddress::Tcp { host, port } => (host, port),
                    #[cfg(unix)]
                    ServerAddress::Unix { .. } => unreachable!(),
                });
                addresses
            };

            for address in added_addresses {
                if self.servers.contains_key(address) {
                    debug_assert!(
                        false,
                        "adding address that already exists in topology: {}",
                        Redact(address)
                    );
                    continue;
                }

                let (monitor_handle, listener) = WorkerHandleListener::channel();
                let monitor_manager = MonitorManager::new(monitor_handle);

                let monitor_request_receiver = MonitorRequestReceiver::new(
                    &monitor_manager,
                    self.topology_watcher.subscribe_to_topology_check_requests(),
                    listener,
                );

                let server = Server::new(
                    address.clone(),
                    self.options.clone(),
                    self.connection_establisher.clone(),
                    self.topology_updater.clone(),
                    self.shutdown.clone(),
                    #[cfg(feature = "tracing-unstable")]
                    self.id,
                );

                self.servers.insert(
                    address.clone(),
                    MonitoredServer {
                        inner: server,
                        monitor_manager,
                    },
                );

                if self.monitoring_enabled() {
                    Monitor::start(
                        address.clone(),
                        self.topology_updater.clone(),
                        self.topology_watcher.clone(),
                        self.event_emitter.clone(),
                        monitor_request_receiver,
                        self.options.clone(),
                        self.connection_establisher.clone(),
                        self.shutdown.clone(),
                    );
                }

                self.emit_event(|| {
                    SdamEvent::ServerOpening(ServerOpeningEvent {
                        address: address.clone(),
                        topology_id: self.id,
                    })
                });
            }
        }

        self.publish_state();
        changed
    }

    /// Mark the server at the given address as Unknown using the provided error as the cause.
    async fn mark_server_as_unknown(&mut self, address: ServerAddress, error: Error) -> bool {
        let description = ServerDescription::new_from_error(address, error);
        self.update_server(description).await
    }

    /// Handle an error that occurred during opreration execution.
    pub(crate) async fn handle_application_error(
        &mut self,
        address: ServerAddress,
        error: Error,
        handshake: HandshakePhase,
    ) -> bool {
        // If the error was due to a misconfigured query, no need to update the topology.
        // e.g. using loadBalanced=true when the server isn't configured to be used with a load
        // balancer.
        if error.is_incompatible_server() {
            return false;
        }

        match self.server_description(&address) {
            Some(sd) => {
                if let Some(existing_tv) = sd.topology_version() {
                    if let Some(tv) = error.topology_version() {
                        // If the error is from a stale topology version, ignore it.
                        if !tv.is_more_recent_than(existing_tv) {
                            return false;
                        }
                    }
                }
            }
            None => return false,
        }

        let mut server = match self.server(&address) {
            Some(s) => s,
            None => return false,
        };

        match &handshake {
            HandshakePhase::PreHello { generation } => {
                match (generation, server.pool.generation()) {
                    (PoolGeneration::Normal(hgen), PoolGeneration::Normal(sgen)) => {
                        if *hgen < sgen {
                            return false;
                        }
                    }
                    // Pre-hello handshake errors are ignored in load-balanced mode.
                    (PoolGeneration::LoadBalanced(_), PoolGeneration::LoadBalanced(_)) => {
                        return false
                    }
                    _ => load_balanced_mode_mismatch!(false),
                }
            }
            HandshakePhase::PostHello { generation }
            | HandshakePhase::AfterCompletion { generation, .. } => {
                if generation.is_stale(&server.pool.generation()) {
                    return false;
                }
            }
        }

        let is_load_balanced =
            self.topology_description.topology_type() == TopologyType::LoadBalanced;
        if error.is_state_change_error() {
            let updated =
                is_load_balanced || self.mark_server_as_unknown(address, error.clone()).await;

            if updated && (error.is_shutting_down() || handshake.wire_version().unwrap_or(0) < 8) {
                server.pool.clear(error, handshake.service_id()).await;
            }
            server.monitor_manager.request_immediate_check();

            updated
        } else if error.is_non_timeout_network_error() || handshake.is_before_completion() {
            if error.contains_label(SYSTEM_OVERLOADED_ERROR) {
                return false;
            }

            let updated = if is_load_balanced {
                // Only clear the pool in load balanced mode if we got far enough in the handshake
                // to determine a serviceId.
                handshake.service_id().is_some()
            } else {
                self.mark_server_as_unknown(server.address.clone(), error.clone())
                    .await
            };

            if updated {
                server
                    .pool
                    .clear(error.clone(), handshake.service_id())
                    .await;
                if !error.is_auth_error() {
                    server.monitor_manager.cancel_in_progress_check(error);
                }
            }
            updated
        } else {
            false
        }
    }

    /// Handle an error that occurred during a monitor check.
    pub(crate) async fn handle_monitor_error(
        &mut self,
        address: ServerAddress,
        error: Error,
    ) -> bool {
        match self.server(&address) {
            Some(server) => {
                let updated = self.mark_server_as_unknown(address, error.clone()).await;
                if updated {
                    // The heartbeat monitor is disabled in load-balanced mode, so this will never
                    // have a service id.
                    server.pool.clear(error, None).await;
                }
                updated
            }
            None => false,
        }
    }

    /// Get the server at the provided address if present in the topology.
    fn server(&self, address: &ServerAddress) -> Option<MonitoredServer> {
        self.servers.get(address).cloned()
    }

    /// Get the server at the provided address if present in the topology.
    fn server_description(&self, address: &ServerAddress) -> Option<ServerDescription> {
        self.topology_description.server(address).cloned()
    }

    fn emit_event(&self, make_event: impl FnOnce() -> SdamEvent) {
        if let Some(ref emitter) = self.event_emitter {
            #[allow(clippy::let_underscore_future)]
            let _ = emitter.emit(make_event());
        }
    }

    fn monitoring_enabled(&self) -> bool {
        #[cfg(test)]
        {
            self.options
                .test_options
                .as_ref()
                .map(|to| to.disable_monitoring_threads)
                != Some(true)
                && self.options.load_balanced != Some(true)
        }

        #[cfg(not(test))]
        {
            self.options.load_balanced != Some(true)
        }
    }
}

/// Struct used to update the topology.
#[derive(Debug, Clone)]
pub(crate) struct TopologyUpdater {
    sender: mpsc::UnboundedSender<AcknowledgedMessage<UpdateMessage, bool>>,
}

impl TopologyUpdater {
    pub(crate) fn channel() -> (TopologyUpdater, TopologyUpdateReceiver) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

        let updater = TopologyUpdater { sender: tx };

        let update_receiver = TopologyUpdateReceiver {
            update_receiver: rx,
        };

        (updater, update_receiver)
    }

    /// Send an update message to the topology.
    async fn send_message(&self, update: UpdateMessage) -> bool {
        let (message, receiver) = AcknowledgedMessage::package(update);

        match self.sender.send(message) {
            Ok(_) => receiver.wait_for_acknowledgment().await.unwrap_or(false),
            _ => false,
        }
    }

    /// Handle an error that occurred during a monitor check.
    pub(crate) async fn handle_monitor_error(&self, address: ServerAddress, error: Error) -> bool {
        self.send_message(UpdateMessage::MonitorError { address, error })
            .await
    }

    /// Handle an error that occurred during operation execution.
    pub(crate) async fn handle_application_error(
        &self,
        address: ServerAddress,
        error: Error,
        phase: HandshakePhase,
    ) -> bool {
        self.send_message(UpdateMessage::ApplicationError {
            address,
            error,
            phase,
        })
        .await
    }

    /// Update the topology using the provided server description, returning a bool
    /// indicating whether the topology changed as a result of the update.
    pub(crate) async fn update(&self, sd: ServerDescription) -> bool {
        self.send_message(UpdateMessage::ServerUpdate(Box::new(sd)))
            .await
    }

    /// Update the topology's highest seen cluster time.
    /// If the provided cluster time is not higher than the topology's currently highest seen
    /// cluster time, this method has no effect.
    pub(crate) async fn advance_cluster_time(&self, to: ClusterTime) {
        self.send_message(UpdateMessage::AdvanceClusterTime(to))
            .await;
    }

    /// Update the provided state to contain the given list of hosts, removing any
    /// existing servers whose addresses aren't present in the list.
    ///
    /// This will start server monitors for the newly added servers.
    pub(crate) async fn sync_hosts(&self, hosts: HashSet<ServerAddress>) {
        self.send_message(UpdateMessage::SyncHosts(hosts)).await;
    }

    pub(crate) async fn fill_pool(&self) {
        self.send_message(UpdateMessage::Broadcast(BroadcastMessage::FillPool))
            .await;
    }

    #[cfg(test)]
    pub(crate) async fn sync_workers(&self) {
        self.send_message(UpdateMessage::Broadcast(BroadcastMessage::SyncWorkers))
            .await;
    }
}

/// Receiver used to listen for updates to the topology.
pub(crate) struct TopologyUpdateReceiver {
    update_receiver: UnboundedReceiver<AcknowledgedMessage<UpdateMessage, bool>>,
}

impl TopologyUpdateReceiver {
    pub(crate) async fn recv(&mut self) -> Option<AcknowledgedMessage<UpdateMessage, bool>> {
        self.update_receiver.recv().await
    }
}

/// Struct used to get the latest topology state and monitor the topology for changes.
#[derive(Debug, Clone)]
pub(crate) struct TopologyWatcher {
    /// Receiver for the latest set of servers and latest TopologyDescription published by the
    /// topology.
    receiver: watch::Receiver<TopologyState>,

    /// Sender used to request a check of the entire topology. The number indicates how many
    /// operations have requested an update and are waiting for the topology to change.
    sender: Arc<watch::Sender<u32>>,

    /// Whether or not this watcher incremented the count in `sender`.
    requested_check: bool,

    #[cfg(test)]
    initialized_receiver: watch::Receiver<bool>,
}

impl TopologyWatcher {
    fn channel(initial_state: TopologyState) -> (TopologyWatcher, TopologyPublisher) {
        #[cfg(test)]
        let (initialized_sender, initialized_receiver) = watch::channel(false);
        let (tx, rx) = watch::channel(initial_state);
        let watcher = TopologyWatcher {
            receiver: rx,
            sender: Arc::new(watch::channel(0).0),
            requested_check: false,
            #[cfg(test)]
            initialized_receiver,
        };
        let publisher = TopologyPublisher {
            state_sender: tx,
            #[cfg(test)]
            initialized_sender,
        };
        (watcher, publisher)
    }

    /// Whether the topology is still active or if all `Client` instances using it have gone
    /// out of scope.
    pub(crate) fn is_alive(&self) -> bool {
        self.receiver.has_changed().is_ok()
    }

    /// Get a server description for the server at the provided address.
    pub(crate) fn server_description(&self, address: &ServerAddress) -> Option<ServerDescription> {
        self.receiver.borrow().description.server(address).cloned()
    }

    /// Clone the latest state, marking it as seen.
    pub(crate) fn observe_latest(&mut self) -> TopologyState {
        self.receiver.borrow_and_update().clone()
    }

    fn subscribe_to_topology_check_requests(&self) -> TopologyCheckRequestReceiver {
        TopologyCheckRequestReceiver {
            receiver: self.sender.subscribe(),
        }
    }

    /// Request that all the monitors associated with the topology perform immediate checks.
    pub(crate) fn request_immediate_check(&mut self) {
        if self.requested_check {
            return;
        }
        self.requested_check = true;

        // Increment the number of operations waiting for a topology update. When the monitors
        // see this, they'll perform checks as soon as possible.
        // Once a change is detected or this watcher is dropped, this will be decremented again.
        self.sender.send_modify(|counter| *counter += 1);
    }

    /// Wait for a new state to be published or for the timeout to be reached, returning a bool
    /// indicating whether an update was seen or not.
    ///
    /// This method marks the new topology state as seen.
    pub(crate) async fn wait_for_update(&mut self, timeout: impl Into<Option<Duration>>) -> bool {
        let changed = if let Some(timeout) = timeout.into() {
            matches!(
                runtime::timeout(timeout, self.receiver.changed()).await,
                Ok(Ok(()))
            )
        } else {
            self.receiver.changed().await.is_ok()
        };

        if changed {
            self.retract_immediate_check_request();
        }

        changed
    }

    fn retract_immediate_check_request(&mut self) {
        if self.requested_check {
            self.requested_check = false;
            self.sender.send_modify(|count| *count -= 1);
        }
    }

    /// Borrow the latest state. This does not mark it as seen.
    ///
    /// Note: this method holds a read lock on the state, so it is best if the borrow is
    /// short-lived. For longer use-cases, clone the `TopologyState` or use `observe_latest`
    /// instead.
    pub(crate) fn peek_latest(&self) -> Ref<'_, TopologyState> {
        self.receiver.borrow()
    }

    pub(crate) fn topology_type(&self) -> TopologyType {
        self.peek_latest().description.topology_type
    }

    pub(crate) fn logical_session_timeout(&self) -> Option<Duration> {
        self.peek_latest().description.logical_session_timeout
    }

    /// Get the topology's currently highest seen cluster time.
    pub(crate) fn cluster_time(&self) -> Option<ClusterTime> {
        self.peek_latest().description.cluster_time().cloned()
    }

    /// Gets the latest information on whether transactions are supported or not.
    pub(crate) fn transaction_support_status(&self) -> TransactionSupportStatus {
        self.peek_latest().description.transaction_support_status()
    }

    /// Updates the given `command` as needed based on the `criteria`.
    pub(crate) fn update_command_with_read_pref(
        &self,
        server_address: &ServerAddress,
        command: &mut Command,
        criteria: &SelectionCriteria,
    ) {
        self.peek_latest()
            .description
            .update_command_with_read_pref(server_address, command, criteria)
    }

    /// Wait until the topology worker has had time to initialize from the initial seed list and
    /// options.
    #[cfg(test)]
    pub(crate) async fn wait_until_initialized(&mut self) {
        while !*self.initialized_receiver.borrow_and_update() {
            if self.initialized_receiver.changed().await.is_err() {
                return;
            }
        }
    }

    /// Gets the addresses of the servers in the cluster.
    #[cfg(test)]
    pub(crate) fn server_addresses(&self) -> HashSet<ServerAddress> {
        self.servers().into_keys().collect()
    }

    /// Gets the addresses of the servers in the cluster.
    /// If the topology hasn't opened yet, this will wait for it.
    #[cfg(test)]
    pub(crate) fn servers(&self) -> HashMap<ServerAddress, Arc<Server>> {
        self.peek_latest().servers()
    }

    #[cfg(test)]
    pub(crate) fn description(&self) -> TopologyDescription {
        self.peek_latest().description.clone()
    }
}

impl Drop for TopologyWatcher {
    fn drop(&mut self) {
        self.retract_immediate_check_request();
    }
}

/// Struct used to broadcast the latest view of the topology.
struct TopologyPublisher {
    state_sender: watch::Sender<TopologyState>,

    /// Sender used (in tests) to indicate when the Topology has been initialized from the inital
    /// seed list and options.
    #[cfg(test)]
    initialized_sender: watch::Sender<bool>,
}

impl TopologyPublisher {
    /// Publish a new state, notifying all the of the outstanding `TopologyWatcher`s.
    ///
    /// Note that even if the provided state is equivalent to the previously broadcasted
    /// `TopologyState`, the watchers will still be notified.
    fn publish_new_state(&self, state: TopologyState) {
        let _ = self.state_sender.send(state);
    }
}

/// Handle used to emit SDAM events.
///
/// If the topology has been closed, events emitted via this handle will not be sent to
/// handlers.
#[derive(Clone)]
pub(crate) struct SdamEventEmitter {
    sender: UnboundedSender<AcknowledgedMessage<SdamEvent>>,
}

impl SdamEventEmitter {
    /// Emit an SDAM event.
    ///
    /// This method returns a future that can be awaited until the event has been actually emitted.
    /// It is not necessary to await this future.
    pub(crate) fn emit(&self, event: impl Into<SdamEvent>) -> impl Future<Output = ()> {
        let (msg, ack) = AcknowledgedMessage::package(event.into());
        // if event handler has stopped listening, no more events should be emitted,
        // so we can safely ignore any send errors here.
        let _ = self.sender.send(msg);

        ack.wait_for_acknowledgment().map(|_| ())
    }
}

/// Enum describing a point in time during an operation's execution relative to when the MongoDB
/// handshake for the conection being used in that operation.
///
/// This is used to determine the error handling semantics for certain error types.
#[derive(Debug, Clone)]
pub(crate) enum HandshakePhase {
    /// Describes a point that occurred before the initial hello completed (e.g. when opening the
    /// socket).
    PreHello { generation: PoolGeneration },

    /// Describes a point in time after the initial hello has completed, but before the entire
    /// handshake (e.g. including authentication) completes.
    PostHello { generation: ConnectionGeneration },

    /// Describes a point in time after the handshake completed (e.g. when the command was sent to
    /// the server).
    AfterCompletion {
        generation: ConnectionGeneration,
        max_wire_version: i32,
    },
}

impl HandshakePhase {
    pub(crate) fn after_completion(handshaked_connection: &PooledConnection) -> Self {
        Self::AfterCompletion {
            generation: handshaked_connection.generation,
            // given that this is a handshaked connection, the stream description should
            // always be available, so 0 should never actually be returned here.
            max_wire_version: handshaked_connection
                .stream_description()
                .ok()
                .and_then(|sd| sd.max_wire_version)
                .unwrap_or(0),
        }
    }

    /// The `serviceId` reported by the server.  If the initial hello has not completed, returns
    /// `None`.
    pub(crate) fn service_id(&self) -> Option<ObjectId> {
        match self {
            HandshakePhase::PreHello { .. } => None,
            HandshakePhase::PostHello { generation, .. } => generation.service_id(),
            HandshakePhase::AfterCompletion { generation, .. } => generation.service_id(),
        }
    }

    /// Whether this phase is before the handshake completed or not.
    fn is_before_completion(&self) -> bool {
        !matches!(self, HandshakePhase::AfterCompletion { .. })
    }

    /// The wire version of the server as reported by the handshake. If the handshake did not
    /// complete, this returns `None`.
    fn wire_version(&self) -> Option<i32> {
        match self {
            HandshakePhase::AfterCompletion {
                max_wire_version, ..
            } => Some(*max_wire_version),
            _ => None,
        }
    }
}

/// Struct used to receive topology-wide immediate check requests from operations in server
/// selection. Such requests can be made through a `TopologyWatcher`.
#[derive(Debug, Clone)]
pub(crate) struct TopologyCheckRequestReceiver {
    /// This receives the number of operations that are blocked waiting for an update to the
    /// topology. If the number is > 0, then that means the monitor should perform a check
    /// ASAP.
    ///
    /// A counter is used here instead of `()` so that operations can retract their requests. This
    /// enables the monitor to unambiguiously determine whether a request is stale or not and
    /// eliminates races between the monitor listening for check requests and operations
    /// actually sending them.
    receiver: watch::Receiver<u32>,
}

impl TopologyCheckRequestReceiver {
    pub(crate) async fn wait_for_check_request(&mut self) {
        while *self.receiver.borrow() == 0 {
            // If all the requesters hung up, then just return early.
            if self.receiver.changed().await.is_err() {
                return;
            };
        }
    }
}

/// Struct wrapping a [`Server`]. When this is dropped, the monitor for this server will close.
#[derive(Debug, Clone)]
struct MonitoredServer {
    inner: Arc<Server>,
    monitor_manager: MonitorManager,
}

impl std::ops::Deref for MonitoredServer {
    type Target = Server;

    fn deref(&self) -> &Self::Target {
        self.inner.deref()
    }
}
