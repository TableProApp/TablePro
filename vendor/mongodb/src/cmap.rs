#[cfg(test)]
pub(crate) mod test;

pub(crate) mod conn;
mod connection_requester;
pub(crate) mod establish;
mod manager;
pub(crate) mod options;
mod status;
mod worker;

use std::time::Instant;

use derive_where::derive_where;

pub use self::conn::ConnectionInfo;
use self::{
    conn::pooled::PooledConnection,
    connection_requester::ConnectionRequestResult,
    establish::ConnectionEstablisher,
    options::ConnectionPoolOptions,
};
pub(crate) use self::{
    conn::{Command, Connection, RawCommandResponse, StreamDescription},
    status::PoolGenerationSubscriber,
    worker::PoolGeneration,
};
use crate::{
    bson::oid::ObjectId,
    error::{Error, Result},
    event::cmap::{
        CmapEvent,
        CmapEventEmitter,
        ConnectionCheckoutFailedEvent,
        ConnectionCheckoutFailedReason,
        ConnectionCheckoutStartedEvent,
        PoolCreatedEvent,
    },
    options::ServerAddress,
    runtime::AcknowledgmentReceiver,
    sdam::{topology::TopologyShutdown, BroadcastMessage, TopologyUpdater},
};
use connection_requester::ConnectionRequester;
use manager::PoolManager;
use worker::ConnectionPoolWorker;

#[cfg(test)]
use crate::runtime::WorkerHandle;

pub(crate) const DEFAULT_MAX_POOL_SIZE: u32 = 10;

/// A pool of connections implementing the CMAP spec.
/// This type is actually a handle to task that manages the connections and is cheap to clone and
/// pass around.
#[derive(Clone)]
#[derive_where(Debug)]
pub(crate) struct ConnectionPool {
    address: ServerAddress,
    manager: PoolManager,
    connection_requester: ConnectionRequester,
    generation_subscriber: PoolGenerationSubscriber,

    #[derive_where(skip)]
    event_emitter: CmapEventEmitter,
}

impl ConnectionPool {
    pub(crate) fn new(
        address: ServerAddress,
        connection_establisher: ConnectionEstablisher,
        server_updater: TopologyUpdater,
        options: Option<ConnectionPoolOptions>,
        shutdown: TopologyShutdown,
        #[cfg(feature = "tracing-unstable")] topology_id: ObjectId,
    ) -> Self {
        let event_handler = options
            .as_ref()
            .and_then(|opts| opts.cmap_event_handler.clone());

        #[cfg(feature = "tracing-unstable")]
        let event_emitter = CmapEventEmitter::new(
            event_handler,
            topology_id,
            options
                .as_ref()
                .and_then(|options| options.max_document_length_bytes),
        );
        #[cfg(not(feature = "tracing-unstable"))]
        let event_emitter = CmapEventEmitter::new(event_handler);

        let (manager, connection_requester, generation_subscriber) = ConnectionPoolWorker::start(
            address.clone(),
            connection_establisher,
            server_updater,
            event_emitter.clone(),
            options.clone(),
            shutdown,
        );

        event_emitter.emit_event(|| {
            CmapEvent::PoolCreated(PoolCreatedEvent {
                address: address.clone(),
                options: options.map(|o| o.to_event_options()),
            })
        });

        Self {
            address,
            manager,
            connection_requester,
            generation_subscriber,
            event_emitter,
        }
    }

    #[cfg(test)]
    pub(crate) fn new_mocked(address: ServerAddress) -> Self {
        let (manager, _) = manager::channel();
        let handle = WorkerHandle::new_mocked();
        let (connection_requester, _) = connection_requester::channel(handle);
        let (_, generation_subscriber) = status::channel(PoolGeneration::normal());

        Self {
            address,
            manager,
            connection_requester,
            generation_subscriber,
            #[cfg(feature = "tracing-unstable")]
            event_emitter: CmapEventEmitter::new(None, ObjectId::new(), None),
            #[cfg(not(feature = "tracing-unstable"))]
            event_emitter: CmapEventEmitter::new(None),
        }
    }

    /// Checks out a connection from the pool. This method will yield until this thread is at the
    /// front of the wait queue, and then will block again if no available connections are in the
    /// pool and the total number of connections is not less than the max pool size.
    pub(crate) async fn check_out(&self) -> Result<PooledConnection> {
        let time_started = Instant::now();
        self.event_emitter.emit_event(|| {
            ConnectionCheckoutStartedEvent {
                address: self.address.clone(),
            }
            .into()
        });

        let response = self.connection_requester.request().await;

        let conn = match response {
            ConnectionRequestResult::Pooled(c) => Ok(*c),
            ConnectionRequestResult::Establishing(task) => task.await,
            ConnectionRequestResult::PoolCleared(e) => {
                Err(Error::pool_cleared_error(&self.address, &e))
            }
            ConnectionRequestResult::PoolWarmed => {
                Err(Error::internal("Invalid result from connection requester"))
            }
        };

        match conn {
            Ok(ref conn) => {
                self.event_emitter
                    .emit_event(|| conn.checked_out_event(time_started).into());
            }

            Err(ref _err) => {
                self.event_emitter.emit_event(|| {
                    ConnectionCheckoutFailedEvent {
                        address: self.address.clone(),
                        reason: ConnectionCheckoutFailedReason::ConnectionError,
                        #[cfg(feature = "tracing-unstable")]
                        error: Some(_err.clone()),
                        duration: Instant::now() - time_started,
                    }
                    .into()
                });
            }
        }

        conn
    }

    /// Increments the generation of the pool. Rather than eagerly removing stale connections from
    /// the pool, they are left for the background thread to clean up.
    pub(crate) async fn clear(&self, cause: Error, service_id: Option<ObjectId>) {
        self.manager.clear(cause, service_id).await
    }

    /// Mark the pool as "ready" as per the CMAP specification.
    pub(crate) async fn mark_as_ready(&self) {
        self.manager.mark_as_ready().await
    }

    pub(crate) fn generation(&self) -> PoolGeneration {
        self.generation_subscriber.generation()
    }

    pub(crate) fn broadcast(&self, msg: BroadcastMessage) -> AcknowledgmentReceiver<()> {
        self.manager.broadcast(msg)
    }
}

pub(crate) fn is_faas() -> bool {
    establish::handshake::FaasEnvironmentName::new().is_some()
}
