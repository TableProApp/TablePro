use tokio::sync::broadcast;

#[cfg(test)]
use super::options::BackgroundThreadInterval;
use super::{
    conn::{pooled::PooledConnection, PendingConnection},
    connection_requester,
    connection_requester::{
        ConnectionRequest,
        ConnectionRequestReceiver,
        ConnectionRequestResult,
        ConnectionRequester,
        WeakConnectionRequester,
    },
    establish::ConnectionEstablisher,
    manager,
    manager::{ConnectionSucceeded, ManagementRequestReceiver, PoolManagementRequest, PoolManager},
    options::ConnectionPoolOptions,
    status,
    status::{PoolGenerationPublisher, PoolGenerationSubscriber},
    DEFAULT_MAX_POOL_SIZE,
};
use crate::{
    bson::oid::ObjectId,
    client::auth::Credential,
    error::{load_balanced_mode_mismatch, Error, ErrorKind, Result},
    event::cmap::{
        CmapEventEmitter,
        ConnectionClosedEvent,
        ConnectionClosedReason,
        PoolClearedEvent,
        PoolClosedEvent,
        PoolReadyEvent,
    },
    options::ServerAddress,
    runtime::{self, WorkerHandleListener},
    sdam::{topology::TopologyShutdown, BroadcastMessage, TopologyUpdater},
};

use std::{
    collections::{HashMap, VecDeque},
    time::{Duration, Instant},
};

const DEFAULT_MAX_CONNECTING: u32 = 2;
const MAINTENACE_FREQUENCY: Duration = Duration::from_millis(500);

/// A worker task that manages the shared state of the pool.
pub(crate) struct ConnectionPoolWorker {
    /// The address the pool's connections will connect to.
    address: ServerAddress,

    /// Current state of the pool. Determines if connections may be checked out
    /// and if min_pool_size connection creation should continue.
    state: PoolState,

    /// The total number of connections managed by the pool, including connections which are
    /// currently checked out of the pool or have yet to be established.
    total_connection_count: u32,

    /// The number of connections currently being established by this pool.
    pending_connection_count: u32,

    /// The ID of the next connection created by the pool.
    next_connection_id: u32,

    /// The current generation of the pool. The generation is incremented whenever the pool is
    /// cleared. Connections belonging to a previous generation are considered stale and will be
    /// closed when checked back in or when popped off of the set of available connections.
    generation: PoolGeneration,

    /// The connection count for each serviceId in load-balanced mode.
    service_connection_count: HashMap<ObjectId, u32>,

    /// The established connections that are currently checked into the pool and awaiting usage in
    /// future operations.
    available_connections: VecDeque<PooledConnection>,

    /// Contains the logic for "establishing" a connection. This includes handshaking and
    /// authenticating a connection when it's first created.
    establisher: ConnectionEstablisher,

    /// The credential used to authenticate connections, if any.
    credential: Option<Credential>,

    /// The type responsible for emitting CMAP events both to an optional user-specified handler
    /// and as tracing events.
    event_emitter: CmapEventEmitter,

    /// The time between maintenance tasks.
    maintenance_frequency: Duration,

    /// Connections that have been ready for usage in the pool for longer than `max_idle_time` will
    /// be closed either by the background thread or when popped off of the set of available
    /// connections. If `max_idle_time` is `None`, then connections will not be closed due to being
    /// idle.
    max_idle_time: Option<Duration>,

    /// The minimum number of connections that the pool can have at a given time. This includes
    /// connections which are currently checked out of the pool. If fewer than `min_pool_size`
    /// connections are in the pool, the background thread will create more connections and add
    /// them to the pool.
    min_pool_size: Option<u32>,

    /// The maximum number of connections that the pool can manage, including connections checked
    /// out of the pool. If a thread requests a connection and the pool is empty + there are
    /// already max_pool_size connections in use, it will block until one is returned or the
    /// wait_queue_timeout is exceeded.
    max_pool_size: u32,

    /// Receiver used to determine if any threads hold references to this pool. If all the
    /// sender ends of this receiver drop, this worker will be notified and drop too.
    handle_listener: WorkerHandleListener,

    /// Sender for connection check out requests.  Does not keep the worker alive the way
    /// a `ConnectionRequeter` would since it doesn't hold a `WorkerHandle`.
    weak_requester: WeakConnectionRequester,

    /// Receiver for incoming connection check out requests.
    request_receiver: ConnectionRequestReceiver,

    /// Ordered queue of incoming requests waiting for connections.
    wait_queue: VecDeque<ConnectionRequest>,

    /// Receiver for incoming pool management requests (e.g. checking in a connection).
    management_receiver: ManagementRequestReceiver,

    /// Sender used to publish the latest generation and notifications for any establishment errors
    /// encountered by the pool.
    generation_publisher: PoolGenerationPublisher,

    /// A pool manager that can be cloned and attached to connections checked out of the pool.
    manager: PoolManager,

    /// A handle used to notify SDAM that a connection establishment error happened. This will
    /// allow the server to transition to Unknown and clear the pool as necessary.
    server_updater: TopologyUpdater,

    /// The maximum number of new connections that can be created concurrently.
    max_connecting: u32,

    /// Sender used to broadcast cancellation notices to checked-out connections.
    cancellation_sender: Option<broadcast::Sender<()>>,

    /// Client shutdown handling.
    shutdown: TopologyShutdown,
}

impl ConnectionPoolWorker {
    /// Starts a worker and returns a manager and connection requester.
    /// Once all connection requesters are dropped, the worker will stop executing
    /// and close the pool.
    pub(super) fn start(
        address: ServerAddress,
        establisher: ConnectionEstablisher,
        server_updater: TopologyUpdater,
        event_emitter: CmapEventEmitter,
        options: Option<ConnectionPoolOptions>,
        shutdown: TopologyShutdown,
    ) -> (PoolManager, ConnectionRequester, PoolGenerationSubscriber) {
        // The CMAP spec indicates that a max idle time of zero means that connections should not be
        // closed due to idleness.
        let mut max_idle_time = options.as_ref().and_then(|opts| opts.max_idle_time);
        if max_idle_time == Some(Duration::from_millis(0)) {
            max_idle_time = None;
        }

        let max_pool_size = options
            .as_ref()
            .and_then(|opts| opts.max_pool_size)
            .unwrap_or(DEFAULT_MAX_POOL_SIZE);
        let max_connecting = options
            .as_ref()
            .and_then(|opts| opts.max_connecting)
            .unwrap_or(DEFAULT_MAX_CONNECTING);

        let min_pool_size = options.as_ref().and_then(|opts| opts.min_pool_size);

        let (handle, handle_listener) = WorkerHandleListener::channel();
        let (connection_requester, request_receiver) = connection_requester::channel(handle);
        let (manager, management_receiver) = manager::channel();

        let is_load_balanced = options
            .as_ref()
            .and_then(|opts| opts.load_balanced)
            .unwrap_or(false);
        let generation = if is_load_balanced {
            PoolGeneration::load_balanced()
        } else {
            PoolGeneration::normal()
        };
        let (generation_publisher, generation_subscriber) = status::channel(generation.clone());

        #[cfg(test)]
        let mut state = if options
            .as_ref()
            .and_then(|opts| opts.ready)
            .unwrap_or(false)
        {
            PoolState::Ready
        } else {
            PoolState::New
        };
        #[cfg(test)]
        let maintenance_frequency = options
            .as_ref()
            .and_then(|opts| opts.background_thread_interval)
            .map(|i| match i {
                // One year is long enough to count as never for tests, but not so long that it
                // will overflow interval math.
                BackgroundThreadInterval::Never => Duration::from_secs(31_556_952),
                BackgroundThreadInterval::Every(d) => d,
            })
            .unwrap_or(MAINTENACE_FREQUENCY);

        #[cfg(not(test))]
        let (mut state, maintenance_frequency) = (PoolState::New, MAINTENACE_FREQUENCY);

        if is_load_balanced {
            // Because load balancer servers don't have a monitoring connection, the associated
            // connection pool needs start in the ready state.
            state = PoolState::Ready;
        }

        let credential = options.and_then(|o| o.credential);

        let cancellation_sender = if !is_load_balanced {
            // There's not necessarily an upper bound on the number of messages that could exist in
            // this channel; however, connections use both successfully receiving a message in the
            // channel and receiving a lagged error as an indication that cancellation should occur,
            // so we use an artificial bound of one message.
            Some(broadcast::channel(1).0)
        } else {
            None
        };

        let worker = ConnectionPoolWorker {
            address,
            event_emitter,
            max_idle_time,
            min_pool_size,
            credential,
            establisher,
            next_connection_id: 1,
            total_connection_count: 0,
            pending_connection_count: 0,
            generation,
            service_connection_count: HashMap::new(),
            available_connections: VecDeque::new(),
            max_pool_size,
            weak_requester: connection_requester.weak(),
            request_receiver,
            wait_queue: Default::default(),
            management_receiver,
            manager: manager.clone(),
            handle_listener,
            state,
            generation_publisher,
            maintenance_frequency,
            server_updater,
            max_connecting,
            cancellation_sender,
            shutdown,
        };

        runtime::spawn(worker.shutdown.tasks.clone().track_future(async move {
            worker.execute().await;
        }));

        (manager, connection_requester, generation_subscriber)
    }

    /// Run the worker thread, listening on the various receivers until all handles have been
    /// dropped. Once all handles are dropped, the pool will close any available connections and
    /// emit a pool closed event.
    async fn execute(mut self) {
        let mut maintenance_interval = tokio::time::interval(self.maintenance_frequency);

        loop {
            let task = tokio::select! {
                // This marker indicates that the futures will be polled in order from top to
                // bottom in this select! macro. We use this to ensure checkIn, clear,
                // and ready always have priority over checkout requests. The pool
                // exiting also has priority.
                biased;

                Some(request) = self.management_receiver.recv() => request.into(),
                _ = self.handle_listener.wait_for_all_handle_drops() => {
                    // all worker handles have been dropped meaning this
                    // pool has no more references and can be dropped itself.
                    break
                },
                Some(request) = self.request_receiver.recv() => {
                    PoolTask::CheckOut(request)
                },
                _ = maintenance_interval.tick() => {
                    PoolTask::Maintenance
                },
                else => {
                    break
                }
            };

            match task {
                PoolTask::CheckOut(request) => match self.state {
                    PoolState::Ready => {
                        self.wait_queue.push_back(request);
                    }
                    PoolState::Paused(ref e) => {
                        // if receiver doesn't listen to error that's ok.
                        let _ = request.fulfill(ConnectionRequestResult::PoolCleared(e.clone()));
                    }
                    PoolState::New => {
                        let _ = request.fulfill(ConnectionRequestResult::PoolCleared(
                            ErrorKind::Internal {
                                message: "check out attempted from new pool".to_string(),
                            }
                            .into(),
                        ));
                    }
                },
                PoolTask::HandleManagementRequest(request) => match *request {
                    PoolManagementRequest::CheckIn(connection) => {
                        self.check_in(*connection);
                    }
                    PoolManagementRequest::Clear {
                        cause, service_id, ..
                    } => {
                        self.clear(cause, service_id);
                    }
                    PoolManagementRequest::MarkAsReady { completion_handler } => {
                        self.mark_as_ready();
                        completion_handler.acknowledge(());
                    }
                    PoolManagementRequest::HandleConnectionSucceeded(conn) => {
                        self.handle_connection_succeeded(conn);
                    }
                    PoolManagementRequest::HandleConnectionFailed => {
                        self.handle_connection_failed();
                    }
                    PoolManagementRequest::Broadcast(msg) => {
                        let (msg, ack) = msg.into_parts();
                        match msg {
                            BroadcastMessage::FillPool => {
                                crate::runtime::spawn(fill_pool(self.weak_requester.clone(), ack));
                            }
                            #[cfg(test)]
                            BroadcastMessage::SyncWorkers => {
                                ack.acknowledge(());
                            }
                        }
                    }
                },
                PoolTask::Maintenance => {
                    self.perform_maintenance();
                }
            }

            if self.can_service_connection_request() {
                if let Some(request) = self.wait_queue.pop_front() {
                    self.check_out(request);
                }
            }
        }

        while let Some(connection) = self.available_connections.pop_front() {
            connection.emit_closed_event(ConnectionClosedReason::PoolClosed);
        }

        self.event_emitter.emit_event(|| {
            PoolClosedEvent {
                address: self.address.clone(),
            }
            .into()
        });
    }

    fn below_max_connections(&self) -> bool {
        self.total_connection_count < self.max_pool_size
    }

    fn can_service_connection_request(&self) -> bool {
        if !matches!(self.state, PoolState::Ready) {
            return false;
        }

        if !self.available_connections.is_empty() {
            return true;
        }

        self.below_max_connections() && self.pending_connection_count < self.max_connecting
    }

    fn check_out(&mut self, request: ConnectionRequest) {
        if request.is_warm_pool() {
            if self.total_connection_count >= self.min_pool_size.unwrap_or(0) {
                let _ = request.fulfill(ConnectionRequestResult::PoolWarmed);
                return;
            }
        } else {
            // first attempt to check out an available connection
            while let Some(mut conn) = self.available_connections.pop_back() {
                // Close the connection if it's stale.
                if conn.generation.is_stale(&self.generation) {
                    self.close_connection(conn, ConnectionClosedReason::Stale);
                    continue;
                }

                // Close the connection if it's idle.
                if conn.is_idle(self.max_idle_time) {
                    self.close_connection(conn, ConnectionClosedReason::Idle);
                    continue;
                }

                conn.mark_checked_out(self.manager.clone(), self.get_cancellation_receiver());
                if let Err(request) =
                    request.fulfill(ConnectionRequestResult::Pooled(Box::new(conn)))
                {
                    // checking out thread stopped listening, indicating it hit the WaitQueue
                    // timeout, so we put connection back into pool.
                    let mut connection = request.unwrap_pooled_connection();
                    connection.mark_checked_in();
                    self.available_connections.push_back(connection);
                }

                return;
            }
        }

        // otherwise, attempt to create a connection.
        if self.below_max_connections() {
            let event_emitter = self.event_emitter.clone();
            let establisher = self.establisher.clone();
            let pending_connection = self.create_pending_connection();
            let manager = self.manager.clone();
            let server_updater = self.server_updater.clone();
            let credential = self.credential.clone();
            let cancellation_receiver = self.get_cancellation_receiver();

            let handle = runtime::spawn(async move {
                let mut establish_result = establish_connection(
                    establisher,
                    pending_connection,
                    server_updater,
                    &manager,
                    credential,
                    event_emitter,
                )
                .await;

                if let Ok(ref mut c) = establish_result {
                    c.mark_checked_out(manager.clone(), cancellation_receiver);
                    manager.handle_connection_succeeded(ConnectionSucceeded::Used {
                        service_id: c.generation.service_id(),
                    });
                }

                establish_result
            });

            // this only fails if the other end stopped listening (e.g. due to timeout), in
            // which case we just let the connection establish in the background.
            let _: std::result::Result<_, _> =
                request.fulfill(ConnectionRequestResult::Establishing(handle));
        } else {
            // put the request to the the front of the wait queue so that it will be processed
            // next time a request can be processed.
            self.wait_queue.push_front(request);
        }
    }

    fn create_pending_connection(&mut self) -> PendingConnection {
        self.total_connection_count += 1;
        self.pending_connection_count += 1;

        let pending_connection = PendingConnection {
            id: self.next_connection_id,
            address: self.address.clone(),
            generation: self.generation.clone(),
            event_emitter: self.event_emitter.clone(),
            time_created: Instant::now(),
            cancellation_receiver: self.get_cancellation_receiver(),
        };
        self.next_connection_id += 1;
        self.event_emitter
            .emit_event(|| pending_connection.created_event().into());

        pending_connection
    }

    /// Process a connection establishment failure.
    fn handle_connection_failed(&mut self) {
        // Establishing a pending connection failed, so that must be reflected in to total
        // connection count.
        self.total_connection_count -= 1;
        self.pending_connection_count -= 1;
    }

    /// Process a successful connection establishment, optionally populating the pool with the
    /// resulting connection.
    fn handle_connection_succeeded(&mut self, connection: ConnectionSucceeded) {
        self.pending_connection_count -= 1;
        if let Some(sid) = connection.service_id() {
            let count = self.service_connection_count.entry(sid).or_insert(0);
            *count += 1;
        }
        if let ConnectionSucceeded::ForPool(connection) = connection {
            let mut connection = *connection;
            connection.mark_checked_in();
            self.available_connections.push_back(connection);
        }
    }

    fn check_in(&mut self, mut conn: PooledConnection) {
        self.event_emitter
            .emit_event(|| conn.checked_in_event().into());

        conn.mark_checked_in();

        if conn.has_errored() {
            self.close_connection(conn, ConnectionClosedReason::Error);
        } else if conn.generation.is_stale(&self.generation) {
            self.close_connection(conn, ConnectionClosedReason::Stale);
        } else if conn.is_executing() {
            self.close_connection(conn, ConnectionClosedReason::Dropped);
        } else {
            self.available_connections.push_back(conn);
        }
    }

    fn clear(&mut self, cause: Error, service_id: Option<ObjectId>) {
        let interrupt_in_use_connections = cause.is_network_timeout();
        if interrupt_in_use_connections {
            if let Some(ref cancellation_sender) = self.cancellation_sender {
                let _ = cancellation_sender.send(());
            }
        }

        let was_ready = match (&mut self.generation, service_id) {
            (PoolGeneration::Normal(gen), None) => {
                *gen += 1;
                let prev = std::mem::replace(&mut self.state, PoolState::Paused(cause.clone()));
                matches!(prev, PoolState::Ready)
            }
            (PoolGeneration::LoadBalanced(gen_map), Some(sid)) => {
                let gen = gen_map.entry(sid).or_insert(0);
                *gen += 1;
                true
            }
            (..) => load_balanced_mode_mismatch!(),
        };
        self.generation_publisher.publish(self.generation.clone());

        if was_ready {
            self.event_emitter.emit_event(|| {
                PoolClearedEvent {
                    address: self.address.clone(),
                    service_id,
                    interrupt_in_use_connections,
                }
                .into()
            });

            if !matches!(self.generation, PoolGeneration::LoadBalanced(_)) {
                for request in self.wait_queue.drain(..) {
                    // an error means the other end hung up already, which is okay because we were
                    // returning an error anyways
                    let _: std::result::Result<_, _> =
                        request.fulfill(ConnectionRequestResult::PoolCleared(cause.clone()));
                }
            }
        }
    }

    fn mark_as_ready(&mut self) {
        if matches!(self.state, PoolState::Ready) {
            return;
        }

        self.state = PoolState::Ready;
        self.event_emitter.emit_event(|| {
            PoolReadyEvent {
                address: self.address.clone(),
            }
            .into()
        });
    }

    /// Close a connection, emit the event for it being closed, and decrement the
    /// total connection count.
    #[allow(clippy::single_match)]
    fn close_connection(&mut self, connection: PooledConnection, reason: ConnectionClosedReason) {
        match (&mut self.generation, connection.generation.service_id()) {
            (PoolGeneration::LoadBalanced(gen_map), Some(sid)) => {
                match self.service_connection_count.get_mut(&sid) {
                    Some(count) => {
                        *count -= 1;
                        if *count == 0 {
                            gen_map.remove(&sid);
                            self.service_connection_count.remove(&sid);
                        }
                    }
                    None => load_balanced_mode_mismatch!(),
                }
            }
            (PoolGeneration::Normal(_), None) => {}
            _ => load_balanced_mode_mismatch!(),
        }
        connection.emit_closed_event(reason);
        self.total_connection_count -= 1;
    }

    /// Ensure all connections in the pool are valid and that the pool is managing at least
    /// min_pool_size connections.
    fn perform_maintenance(&mut self) {
        self.remove_perished_connections();
        if matches!(self.state, PoolState::Ready) {
            self.ensure_min_connections();
        }
    }

    /// Iterate over the connections and remove any that are stale or idle.
    fn remove_perished_connections(&mut self) {
        while let Some(connection) = self.available_connections.pop_front() {
            if connection.generation.is_stale(&self.generation) {
                // the following unwrap is okay becaue we asserted the pool was nonempty
                self.close_connection(connection, ConnectionClosedReason::Stale);
            } else if connection.is_idle(self.max_idle_time) {
                self.close_connection(connection, ConnectionClosedReason::Idle);
            } else {
                self.available_connections.push_front(connection);
                // All subsequent connections are either not idle or not stale since they were
                // checked into the pool later, so we can just quit early.
                break;
            };
        }
    }

    /// Populate the the pool with enough connections to meet the min_pool_size_requirement.
    fn ensure_min_connections(&mut self) {
        if let Some(min_pool_size) = self.min_pool_size {
            while self.total_connection_count < min_pool_size
                && self.pending_connection_count < self.max_connecting
            {
                let pending_connection = self.create_pending_connection();
                let event_handler = self.event_emitter.clone();
                let manager = self.manager.clone();
                let establisher = self.establisher.clone();
                let updater = self.server_updater.clone();
                let credential = self.credential.clone();

                runtime::spawn(async move {
                    let connection = establish_connection(
                        establisher,
                        pending_connection,
                        updater,
                        &manager,
                        credential,
                        event_handler,
                    )
                    .await;

                    if let Ok(connection) = connection {
                        manager.handle_connection_succeeded(ConnectionSucceeded::ForPool(Box::new(
                            connection,
                        )))
                    }
                });
            }
        }
    }

    /// Returns a receiver for the pool's cancellation sender if this pool is not in load-balanced
    /// mode. The returned receiver will only receive messages sent after this method is called.
    fn get_cancellation_receiver(&self) -> Option<broadcast::Receiver<()>> {
        self.cancellation_sender
            .as_ref()
            .map(|sender| sender.subscribe())
    }
}

/// Helper covering the common connection establishment behavior between
/// connections established in check_out and those established as part of
/// satisfying min_pool_size.
async fn establish_connection(
    establisher: ConnectionEstablisher,
    pending_connection: PendingConnection,
    server_updater: TopologyUpdater,
    manager: &PoolManager,
    credential: Option<Credential>,
    event_emitter: CmapEventEmitter,
) -> Result<PooledConnection> {
    let connection_id = pending_connection.id;
    let address = pending_connection.address.clone();

    let mut establish_result = establisher
        .establish_connection(pending_connection, credential.as_ref())
        .await;

    match establish_result {
        Err(ref e) => {
            server_updater
                .handle_application_error(
                    address.clone(),
                    e.cause.clone(),
                    e.handshake_phase.clone(),
                )
                .await;
            event_emitter.emit_event(|| {
                ConnectionClosedEvent {
                    address,
                    reason: ConnectionClosedReason::Error,
                    connection_id,
                    #[cfg(feature = "tracing-unstable")]
                    error: Some(e.cause.clone()),
                    service_id: None,
                }
                .into()
            });
            manager.handle_connection_failed();
        }
        Ok(ref mut connection) => {
            event_emitter.emit_event(|| connection.ready_event().into());
        }
    }

    establish_result.map_err(|e| e.cause)
}

async fn fill_pool(
    requester: WeakConnectionRequester,
    ack: crate::runtime::AcknowledgmentSender<()>,
) {
    let mut establishing = vec![];
    loop {
        let result = requester.request_warm_pool().await;
        match result {
            None => break,
            Some(ConnectionRequestResult::Establishing(handle)) => {
                // Let connections finish establishing in parallel.
                establishing.push(crate::runtime::spawn(async move {
                    let _ = handle.await;
                    // The connection is dropped here, returning it to the pool.
                }));
            }
            _ => break,
        };
    }
    // Wait for all connections to finish establishing before reporting completion.
    futures_util::future::join_all(establishing).await;
    ack.acknowledge(());
}

/// Enum modeling the possible pool states as described in the CMAP spec.
///
/// The "closed" state is omitted here because the pool considered closed only
/// once it goes out of scope and cannot be manually closed before then.
#[derive(Debug)]
enum PoolState {
    /// Same as Paused, but only for a new pool, not one that has been cleared due to an error.
    New,

    /// Connections may not be checked out nor created in the background to satisfy minPoolSize.
    Paused(Error),

    /// Pool is operational.
    Ready,
}

/// Task to process by the worker.
#[derive(Debug)]
enum PoolTask {
    /// Handle a management request from a `PoolManager`.
    HandleManagementRequest(Box<PoolManagementRequest>),

    /// Fulfill the given connection request.
    CheckOut(ConnectionRequest),

    /// Perform pool maintenance (ensure min connections, remove stale or idle connections).
    Maintenance,
}

impl From<PoolManagementRequest> for PoolTask {
    fn from(request: PoolManagementRequest) -> Self {
        PoolTask::HandleManagementRequest(Box::new(request))
    }
}

#[derive(Debug, Clone)]
pub(crate) enum PoolGeneration {
    Normal(u32),
    LoadBalanced(HashMap<ObjectId, u32>),
}

impl PoolGeneration {
    pub(crate) fn normal() -> Self {
        Self::Normal(0)
    }

    fn load_balanced() -> Self {
        Self::LoadBalanced(HashMap::new())
    }

    #[cfg(test)]
    pub(crate) fn as_normal(&self) -> Option<u32> {
        match self {
            PoolGeneration::Normal(n) => Some(*n),
            _ => None,
        }
    }
}
