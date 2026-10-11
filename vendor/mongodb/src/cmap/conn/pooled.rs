use std::{
    ops::{Deref, DerefMut},
    sync::Arc,
    time::{Duration, Instant},
};

use derive_where::derive_where;
use tokio::sync::{broadcast, mpsc, Mutex};

use super::{
    CmapEventEmitter,
    Connection,
    ConnectionGeneration,
    ConnectionInfo,
    Message,
    PendingConnection,
    PinnedConnectionHandle,
    PoolManager,
    RawCommandResponse,
};
use crate::{
    bson::oid::ObjectId,
    cmap::{PoolGeneration, StreamDescription},
    error::{Error, Result},
    event::cmap::{
        ConnectionCheckedInEvent,
        ConnectionCheckedOutEvent,
        ConnectionClosedEvent,
        ConnectionClosedReason,
        ConnectionReadyEvent,
    },
    runtime::AsyncStream,
    ServerType,
};

/// A wrapper around the [`Connection`] type that represents a connection within a connection pool.
/// This type derefs into [`Connection`], so fields and methods exposed on that type can be called
/// directly from this one.
#[derive_where(Debug)]
pub(crate) struct PooledConnection {
    /// The connection this pooled connection wraps.
    connection: Connection,

    /// The connection pool generation from which this connection was checked out.
    pub(crate) generation: ConnectionGeneration,

    /// Emitter for events related to this connection.
    #[derive_where(skip)]
    event_emitter: CmapEventEmitter,

    /// The state of this connection.
    state: PooledConnectionState,
}

/// The state of a pooled connection.
#[derive(Debug)]
enum PooledConnectionState {
    /// The state associated with a connection checked into the connection pool.
    CheckedIn { available_time: Instant },

    /// The state associated with a connection checked out of the connection pool.
    CheckedOut {
        /// The manager used to check this connection back into the pool.
        pool_manager: PoolManager,

        /// The receiver to receive a cancellation notice. Only present on non-load-balanced
        /// connections.
        cancellation_receiver: Option<broadcast::Receiver<()>>,
    },

    /// The state associated with a pinned connection.
    Pinned {
        /// The state of the pinned connection.
        pinned_state: PinnedState,

        pinned_sender: mpsc::Sender<PooledConnection>,

        /// The manager used to check this connection back into the pool.
        pool_manager: PoolManager,
    },
}

/// The state of a pinned connection.
#[derive(Clone, Debug)]
enum PinnedState {
    /// The state associated with a pinned connection that is currently in use.
    InUse,

    /// The state associated with a pinned connection that has been returned to its pinner.
    Returned {
        /// The time at which the connection was returned to its pinner.
        returned_time: Instant,
    },
}

impl Deref for PooledConnection {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        &self.connection
    }
}

impl DerefMut for PooledConnection {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.connection
    }
}

impl PooledConnection {
    /// Creates a new pooled connection in the checked-in state.
    pub(crate) fn new(pending_connection: PendingConnection, stream: AsyncStream) -> Self {
        let connection = Connection::new(
            pending_connection.address,
            stream,
            pending_connection.id,
            pending_connection.time_created,
        );
        let generation = match pending_connection.generation {
            PoolGeneration::Normal(generation) => ConnectionGeneration::Normal(generation),
            PoolGeneration::LoadBalanced(_) => ConnectionGeneration::LoadBalanced(None),
        };
        Self {
            connection,
            generation,
            event_emitter: pending_connection.event_emitter,
            state: PooledConnectionState::CheckedIn {
                available_time: Instant::now(),
            },
        }
    }

    pub(crate) fn info(&self) -> ConnectionInfo {
        ConnectionInfo {
            id: self.connection.id,
            server_id: self.server_id,
            address: self.connection.address.clone(),
        }
    }

    /// The service ID for this connection. Only returns a value if this connection is to a load
    /// balancer.
    pub(crate) fn service_id(&self) -> Option<ObjectId> {
        self.stream_description
            .as_ref()
            .and_then(|sd| sd.service_id)
    }

    /// Sends a message on this connection.
    pub(crate) async fn send_message(
        &mut self,
        message: impl TryInto<Message, Error = impl Into<Error>>,
    ) -> Result<RawCommandResponse> {
        match self.state {
            PooledConnectionState::CheckedOut {
                cancellation_receiver: Some(ref mut cancellation_receiver),
                ..
            } => {
                self.connection
                    .send_message_with_cancellation(message, cancellation_receiver)
                    .await
            }
            _ => self.connection.send_message(message).await,
        }
    }

    /// Updates the state of the connection to indicate that it is checked into the pool.
    pub(crate) fn mark_checked_in(&mut self) {
        if !matches!(self.state, PooledConnectionState::CheckedIn { .. }) {
            let available_time = match self.state {
                PooledConnectionState::Pinned {
                    pinned_state: PinnedState::Returned { returned_time },
                    ..
                } => returned_time,
                _ => Instant::now(),
            };
            self.state = PooledConnectionState::CheckedIn { available_time };
        }
    }

    /// Updates the state of the connection to indicate that it is checked out of the pool.
    pub(crate) fn mark_checked_out(
        &mut self,
        pool_manager: PoolManager,
        cancellation_receiver: Option<broadcast::Receiver<()>>,
    ) {
        self.state = PooledConnectionState::CheckedOut {
            pool_manager,
            cancellation_receiver,
        };
    }

    /// Whether this connection is idle.
    pub(crate) fn is_idle(&self, max_idle_time: Option<Duration>) -> bool {
        let Some(max_idle_time) = max_idle_time else {
            return false;
        };
        let available_time = match self.state {
            PooledConnectionState::CheckedIn { available_time } => available_time,
            PooledConnectionState::Pinned {
                pinned_state: PinnedState::Returned { returned_time },
                ..
            } => returned_time,
            _ => return false,
        };
        Instant::now().duration_since(available_time) >= max_idle_time
    }

    pub(crate) fn is_pinned(&self) -> bool {
        matches!(self.state, PooledConnectionState::Pinned { .. })
    }

    /// Whether this connection is to a mongos.
    pub(crate) fn is_sharded(&self) -> Result<bool> {
        Ok(self.stream_description()?.initial_server_type == ServerType::Mongos)
    }

    /// Nullifies the internal state of this connection and returns it in a new [PooledConnection]
    /// with the given state.
    fn take(&mut self, new_state: PooledConnectionState) -> Self {
        Self {
            connection: self.connection.take(),
            generation: self.generation,
            event_emitter: self.event_emitter.clone(),
            state: new_state,
        }
    }

    /// Pin the connection and return a handle to the pinned connection.
    pub(crate) fn pin(&mut self) -> Result<PinnedConnectionHandle> {
        match &mut self.state {
            PooledConnectionState::CheckedIn { .. } => Err(Error::internal(format!(
                "cannot pin a checked-in connection (id = {})",
                self.id
            ))),
            PooledConnectionState::CheckedOut {
                ref pool_manager, ..
            } => {
                let (tx, rx) = mpsc::channel(1);
                self.state = PooledConnectionState::Pinned {
                    // Mark the connection as in-use while the operation currently using the
                    // connection finishes. Once that operation drops the connection, it will be
                    // sent back to the pinner.
                    pinned_sender: tx,
                    pinned_state: PinnedState::InUse,
                    pool_manager: pool_manager.clone(),
                };

                Ok(PinnedConnectionHandle {
                    id: self.id,
                    receiver: Arc::new(Mutex::new(rx)),
                })
            }
            PooledConnectionState::Pinned { .. } => Err(Error::internal(format!(
                "cannot pin an already-pinned connection (id = {})",
                self.id
            ))),
        }
    }

    pub(crate) fn mark_pinned_in_use(&mut self) {
        match self.state {
            PooledConnectionState::Pinned {
                ref mut pinned_state,
                ..
            } => {
                *pinned_state = PinnedState::InUse;
            }
            _ => {
                if cfg!(debug_assertions) {
                    panic!("attempting to mark a non-pinned connection in use")
                }
            }
        }
    }

    /// Emit a [`ConnectionClosedEvent`] for this connection with the supplied reason.
    pub(crate) fn emit_closed_event(&self, reason: ConnectionClosedReason) {
        self.event_emitter
            .emit_event(|| self.closed_event(reason).into());
    }

    pub(crate) fn stream_description(&self) -> Result<&StreamDescription> {
        self.connection.stream_description()
    }

    /// Whether the connection supports sessions.
    pub(crate) fn supports_sessions(&self) -> bool {
        self.connection
            .stream_description
            .as_ref()
            .and_then(|sd| sd.logical_session_timeout)
            .is_some()
    }

    /// Helper to create a [`ConnectionCheckedOutEvent`] for the connection.
    pub(crate) fn checked_out_event(&self, time_started: Instant) -> ConnectionCheckedOutEvent {
        ConnectionCheckedOutEvent {
            address: self.connection.address.clone(),
            connection_id: self.connection.id,
            duration: Instant::now() - time_started,
        }
    }

    /// Helper to create a [`ConnectionCheckedInEvent`] for the connection.
    pub(crate) fn checked_in_event(&self) -> ConnectionCheckedInEvent {
        ConnectionCheckedInEvent {
            address: self.connection.address.clone(),
            connection_id: self.connection.id,
        }
    }

    /// Helper to create a [`ConnectionReadyEvent`] for the connection.
    pub(crate) fn ready_event(&self) -> ConnectionReadyEvent {
        ConnectionReadyEvent {
            address: self.connection.address.clone(),
            connection_id: self.connection.id,
            duration: Instant::now() - self.connection.time_created,
        }
    }

    /// Helper to create a [`ConnectionClosedEvent`] for the connection.
    pub(super) fn closed_event(&self, reason: ConnectionClosedReason) -> ConnectionClosedEvent {
        ConnectionClosedEvent {
            address: self.connection.address.clone(),
            connection_id: self.connection.id,
            reason,
            #[cfg(feature = "tracing-unstable")]
            error: self.connection.error.clone(),
            service_id: self.service_id(),
        }
    }
}

impl Drop for PooledConnection {
    fn drop(&mut self) {
        let result = match &self.state {
            // Nothing needs to be done when a checked-in connection is dropped.
            PooledConnectionState::CheckedIn { .. } => Ok(()),
            // A checked-out connection should be sent back to the connection pool.
            PooledConnectionState::CheckedOut { pool_manager, .. } => {
                let pool_manager = pool_manager.clone();
                let dropped_connection = self.take(PooledConnectionState::CheckedIn {
                    available_time: Instant::now(),
                });
                pool_manager.check_in(dropped_connection)
            }
            // A pinned connection should be returned to its pinner or to the connection pool.
            PooledConnectionState::Pinned {
                pinned_sender,
                pinned_state,
                pool_manager,
            } => {
                let pool_manager = pool_manager.clone();
                match pinned_state {
                    // If the pinned connection is in use, it is being dropped at the end of an
                    // operation and should be sent back to its pinner.
                    PinnedState::InUse => {
                        let pinned_sender = pinned_sender.clone();

                        let dropped_connection = self.take(PooledConnectionState::Pinned {
                            pinned_sender: pinned_sender.clone(),
                            pinned_state: PinnedState::Returned {
                                returned_time: Instant::now(),
                            },
                            pool_manager: pool_manager.clone(),
                        });

                        if let Err(send_error) = pinned_sender.try_send(dropped_connection) {
                            use mpsc::error::TrySendError;
                            let returned_connection = match send_error {
                                // The connection is being returned to the pin holder while another
                                // connection is in the pin buffer; this should never happen. Panic
                                // in debug mode and send the connection back to the pool.
                                TrySendError::Full(returned_connection) => {
                                    if cfg!(debug_assertions) {
                                        panic!(
                                            "buffer full when attempting to return pinned \
                                             connection to its pinner (id: {})",
                                            self.id
                                        );
                                    }
                                    returned_connection
                                }
                                // The pinner has dropped, so the connection should be returned to
                                // the pool.
                                TrySendError::Closed(returned_connection) => returned_connection,
                            };

                            pool_manager.check_in(returned_connection)
                        } else {
                            Ok(())
                        }
                    }
                    // The pinner of this connection has been dropped while the connection was
                    // sitting in its channel, so the connection should be returned to the pool.
                    PinnedState::Returned { .. } => {
                        pool_manager.check_in(self.take(PooledConnectionState::CheckedIn {
                            available_time: Instant::now(),
                        }))
                    }
                }
            }
        };

        // Checking in the connection failed because the pool has closed, so emit an event.
        if let Err(mut returned_connection) = result {
            // Mark as checked in to prevent a drop cycle.
            returned_connection.mark_checked_in();
            returned_connection.emit_closed_event(ConnectionClosedReason::PoolClosed);
        }
    }
}
