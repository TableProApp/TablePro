//! Contains the events and functionality for monitoring behavior of the connection pooling of a
//! `Client`.

use std::time::Duration;

use derive_more::From;
#[cfg(feature = "tracing-unstable")]
use derive_where::derive_where;
use serde::{Deserialize, Serialize};

use crate::{bson::oid::ObjectId, options::ServerAddress, serde_util};

#[cfg(feature = "tracing-unstable")]
use crate::trace::{
    connection::ConnectionTracingEventEmitter,
    trace_or_log_enabled,
    TracingOrLogLevel,
    CONNECTION_TRACING_EVENT_TARGET,
};

use super::EventHandler;

/// We implement `Deserialize` for all of the event types so that we can more easily parse the CMAP
/// spec tests. However, we have no need to parse the address field from the JSON files (if it's
/// even present). To facilitate populating the address field with an empty value when
/// deserializing, we define a private `empty_address` function that the events can specify as the
/// custom deserialization value for each address field.
fn empty_address() -> ServerAddress {
    ServerAddress::Tcp {
        host: Default::default(),
        port: None,
    }
}

/// Event emitted when a connection pool is created.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[non_exhaustive]
pub struct PoolCreatedEvent {
    /// The address of the server that the pool's connections will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The options used for the pool.
    pub options: Option<ConnectionPoolOptions>,
}

/// Contains the options for creating a connection pool. While these options are specified at the
/// client-level, `ConnectionPoolOptions` is exposed for the purpose of CMAP event handling.
#[derive(Clone, Default, Deserialize, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionPoolOptions {
    /// Connections that have been ready for usage in the pool for longer than `max_idle_time` will
    /// not be used.
    ///
    /// The default is that connections will not be closed due to being idle.
    #[serde(rename = "maxIdleTimeMS")]
    #[serde(default)]
    #[serde(deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis")]
    pub max_idle_time: Option<Duration>,

    /// The maximum number of connections that the pool can have at a given time. This includes
    /// connections which are currently checked out of the pool.
    ///
    /// The default is 10.
    pub max_pool_size: Option<u32>,

    /// The minimum number of connections that the pool can have at a given time. This includes
    /// connections which are currently checked out of the pool. If fewer than `min_pool_size`
    /// connections are in the pool, connections will be added to the pool in the background.
    ///
    /// The default is that no minimum is enforced
    pub min_pool_size: Option<u32>,
}

/// Event emitted when a connection pool becomes ready.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[non_exhaustive]
pub struct PoolReadyEvent {
    /// The address of the server that the pool's connections will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,
}

/// Event emitted when a connection pool is cleared.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[non_exhaustive]
pub struct PoolClearedEvent {
    /// The address of the server that the pool's connections will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// If the connection is to a load balancer, the id of the selected backend.
    pub service_id: Option<ObjectId>,

    /// Whether in-use connections were interrupted when the pool cleared.
    #[serde(default)]
    pub interrupt_in_use_connections: bool,
}

/// Event emitted when a connection pool is cleared.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[non_exhaustive]
pub struct PoolClosedEvent {
    /// The address of the server that the pool's connections will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,
}

/// Event emitted when a connection is created.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionCreatedEvent {
    /// The address of the server that the connection will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The unique ID of the connection. This is not used for anything internally, but can be used
    /// to identify other events related to this connection.
    #[serde(default = "default_connection_id")]
    pub connection_id: u32,
}

/// Event emitted when a connection is ready to be used. This indicates that all the necessary
/// prerequisites for using a connection (handshake, authentication, etc.) have been completed.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionReadyEvent {
    /// The address of the server that the connection is connected to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The unique ID of the connection. This is not used for anything internally, but can be used
    /// to identify other events related to this connection.
    #[serde(default = "default_connection_id")]
    pub connection_id: u32,

    /// The time it took to establish the connection.
    #[serde(skip_deserializing)]
    pub duration: Duration,
}

/// Event emitted when a connection is closed.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[cfg_attr(feature = "tracing-unstable", derive_where(PartialEq))]
#[cfg_attr(not(feature = "tracing-unstable"), derive(PartialEq))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionClosedEvent {
    /// The address of the server that the connection was connected to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The unique ID of the connection. This is not used for anything internally, but can be used
    /// to identify other events related to this connection.
    #[serde(default)]
    pub connection_id: u32,

    /// The reason that the connection was closed.
    #[cfg_attr(test, serde(default = "unset_connection_closed_reason"))]
    pub reason: ConnectionClosedReason,

    /// If the `reason` connection checkout failed was `Error`,the associated
    /// error is contained here. This is attached so we can include it in log messages;
    /// in future work we may add this to public API on the event itself. TODO: DRIVERS-2495
    #[cfg(feature = "tracing-unstable")]
    #[serde(skip)]
    #[derive_where(skip)]
    pub(crate) error: Option<crate::error::Error>,

    pub(crate) service_id: Option<ObjectId>,
}

/// The reasons that a connection may be closed.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum ConnectionClosedReason {
    /// The connection pool has been cleared since the connection was created.
    Stale,

    /// The connection has been available for longer than `max_idle_time` without being used.
    Idle,

    /// An error occurred while using the connection.
    Error,

    /// The connection was dropped during read or write.
    Dropped,

    /// The pool that the connection belongs to has been closed.
    PoolClosed,

    #[cfg(test)]
    /// The value was not set in the test file.
    Unset,
}

#[cfg(test)]
fn unset_connection_closed_reason() -> ConnectionClosedReason {
    ConnectionClosedReason::Unset
}

/// Event emitted when a thread begins checking out a connection to use for an operation.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[non_exhaustive]
pub struct ConnectionCheckoutStartedEvent {
    /// The address of the server that the connection will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,
}

/// Event emitted when a thread is unable to check out a connection.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[cfg_attr(feature = "tracing-unstable", derive_where(PartialEq))]
#[cfg_attr(not(feature = "tracing-unstable"), derive(PartialEq))]
#[non_exhaustive]
pub struct ConnectionCheckoutFailedEvent {
    /// The address of the server that the connection would have connected to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The reason a connection was unable to be checked out.
    #[cfg_attr(test, serde(default = "unset_connection_checkout_failed_reason"))]
    pub reason: ConnectionCheckoutFailedReason,

    /// If the `reason` connection checkout failed was `ConnectionError`,the associated
    /// error is contained here. This is attached so we can include it in log messages;
    /// in future work we may add this to public API on the event itself. TODO: DRIVERS-2495
    #[cfg(feature = "tracing-unstable")]
    #[serde(skip)]
    #[derive_where(skip)]
    pub(crate) error: Option<crate::error::Error>,

    /// See [ConnectionCheckedOutEvent::duration].
    #[serde(skip_deserializing)]
    pub duration: Duration,
}

/// The reasons a connection may not be able to be checked out.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum ConnectionCheckoutFailedReason {
    /// The `wait_queue_timeout` has elapsed while waiting for a connection to be available.
    Timeout,

    /// An error occurred while trying to establish a connection (e.g. during the handshake or
    /// authentication).
    ConnectionError,

    #[cfg(test)]
    /// The value was not set in the test file.
    Unset,
}

#[cfg(test)]
fn unset_connection_checkout_failed_reason() -> ConnectionCheckoutFailedReason {
    ConnectionCheckoutFailedReason::Unset
}

/// Event emitted when a connection is successfully checked out.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionCheckedOutEvent {
    /// The address of the server that the connection will connect to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The unique ID of the connection. This is not used for anything internally, but can be used
    /// to identify other events related to this connection.
    #[serde(default = "default_connection_id")]
    pub connection_id: u32,

    /// The time it took to check out the connection.
    #[serde(skip_deserializing)]
    pub duration: Duration,
}

/// Event emitted when a connection is checked back into a connection pool.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionCheckedInEvent {
    /// The address of the server that the connection was connected to.
    #[serde(default = "self::empty_address")]
    #[serde(skip_deserializing)]
    pub address: ServerAddress,

    /// The unique ID of the connection. This is not used for anything internally, but can be used
    /// to identify other events related to this connection.
    #[serde(default = "default_connection_id")]
    pub connection_id: u32,
}

/// The default connection ID to use for deserialization of events from test files.
/// This value will "match" any connection ID.
fn default_connection_id() -> u32 {
    42
}

/// Usage of this trait is deprecated.  Applications should use the [`EventHandler`] API.
///
/// Applications can implement this trait to specify custom logic to run on each CMAP event sent
/// by the driver.
///
/// ```rust
/// # #![allow(deprecated)]
/// # use std::sync::Arc;
/// #
/// # use mongodb::{
/// #     error::Result,
/// #     event::cmap::{
/// #         CmapEventHandler,
/// #         ConnectionCheckoutFailedEvent
/// #     },
/// #     options::ClientOptions,
/// # };
/// # #[cfg(feature = "sync")]
/// # use mongodb::sync::Client;
/// # #[cfg(not(feature = "sync"))]
/// # use mongodb::Client;
/// #
/// struct FailedCheckoutLogger;
///
/// impl CmapEventHandler for FailedCheckoutLogger {
///     fn handle_connection_checkout_failed_event(&self, event: ConnectionCheckoutFailedEvent) {
///         eprintln!("Failed connection checkout: {:?}", event);
///     }
/// }
///
/// # fn do_stuff() -> Result<()> {
/// let handler = Arc::new(FailedCheckoutLogger);
/// let options = ClientOptions::builder()
///                   .cmap_event_handler(handler)
///                   .build();
/// let client = Client::with_options(options)?;
///
/// // Do things with the client, and failed connection pool checkouts will be logged to stderr.
/// # Ok(())
/// # }
/// ```
#[deprecated = "use the EventHandler API"]
pub trait CmapEventHandler: Send + Sync {
    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection pool is created.
    fn handle_pool_created_event(&self, _event: PoolCreatedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection pool marked as ready for use.
    ///
    /// Connections may not be created by or checked out from the pool until it has been marked as
    /// ready.
    fn handle_pool_ready_event(&self, _event: PoolReadyEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection pool is cleared.
    fn handle_pool_cleared_event(&self, _event: PoolClearedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection pool is cleared.
    fn handle_pool_closed_event(&self, _event: PoolClosedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection is created.
    fn handle_connection_created_event(&self, _event: ConnectionCreatedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection is ready to be used.
    fn handle_connection_ready_event(&self, _event: ConnectionReadyEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection is closed.
    fn handle_connection_closed_event(&self, _event: ConnectionClosedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a thread begins checking out a connection to use for an operation.
    fn handle_connection_checkout_started_event(&self, _event: ConnectionCheckoutStartedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a thread is unable to check out a connection.
    fn handle_connection_checkout_failed_event(&self, _event: ConnectionCheckoutFailedEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection is successfully checked out.
    fn handle_connection_checked_out_event(&self, _event: ConnectionCheckedOutEvent) {}

    /// A [`Client`](../../struct.Client.html) will call this method on each registered handler
    /// whenever a connection is checked back into a connection pool.
    fn handle_connection_checked_in_event(&self, _event: ConnectionCheckedInEvent) {}
}

#[derive(Clone, Debug, PartialEq, From)]
#[non_exhaustive]
#[allow(missing_docs)]
pub enum CmapEvent {
    PoolCreated(PoolCreatedEvent),
    PoolReady(PoolReadyEvent),
    PoolCleared(PoolClearedEvent),
    PoolClosed(PoolClosedEvent),
    ConnectionCreated(ConnectionCreatedEvent),
    ConnectionReady(ConnectionReadyEvent),
    ConnectionClosed(ConnectionClosedEvent),
    ConnectionCheckoutStarted(ConnectionCheckoutStartedEvent),
    ConnectionCheckoutFailed(ConnectionCheckoutFailedEvent),
    ConnectionCheckedOut(ConnectionCheckedOutEvent),
    ConnectionCheckedIn(ConnectionCheckedInEvent),
}

#[derive(Clone)]
pub(crate) struct CmapEventEmitter {
    user_handler: Option<EventHandler<CmapEvent>>,

    #[cfg(feature = "tracing-unstable")]
    tracing_emitter: ConnectionTracingEventEmitter,
}

impl CmapEventEmitter {
    pub(crate) fn new(
        user_handler: Option<EventHandler<CmapEvent>>,
        #[cfg(feature = "tracing-unstable")] topology_id: ObjectId,
        #[cfg(feature = "tracing-unstable")] max_document_length_bytes: Option<usize>,
    ) -> CmapEventEmitter {
        Self {
            user_handler,
            #[cfg(feature = "tracing-unstable")]
            tracing_emitter: ConnectionTracingEventEmitter::new(
                topology_id,
                max_document_length_bytes,
            ),
        }
    }

    #[cfg(not(feature = "tracing-unstable"))]
    pub(crate) fn emit_event(&self, generate_event: impl FnOnce() -> CmapEvent) {
        if let Some(ref handler) = self.user_handler {
            handler.handle(generate_event());
        }
    }

    #[cfg(feature = "tracing-unstable")]
    pub(crate) fn emit_event(&self, generate_event: impl FnOnce() -> CmapEvent) {
        // if the user isn't actually interested in debug-level connection messages, we shouldn't
        // bother with the expense of generating and emitting these events.
        let tracing_emitter_to_use = if trace_or_log_enabled!(
            target: CONNECTION_TRACING_EVENT_TARGET,
            TracingOrLogLevel::Debug
        ) {
            Some(&self.tracing_emitter)
        } else {
            None
        };

        match (&self.user_handler, tracing_emitter_to_use) {
            (None, None) => {}
            (None, Some(tracing_emitter)) => {
                let event = generate_event();
                tracing_emitter.handle(event);
            }
            (Some(user_handler), None) => {
                let event = generate_event();
                user_handler.handle(event);
            }
            (Some(user_handler), Some(tracing_emitter)) => {
                let event = generate_event();
                user_handler.handle(event.clone());
                tracing_emitter.handle(event);
            }
        };
    }
}
