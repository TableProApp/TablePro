mod command;
pub(crate) mod pooled;
mod stream_description;
pub(crate) mod wire;

use std::{sync::Arc, time::Instant};

use derive_where::derive_where;
use serde::Serialize;
use tokio::{
    io::BufStream,
    sync::{
        broadcast::{self, error::RecvError},
        mpsc,
        Mutex,
    },
};

use self::wire::{Message, MessageFlags};
use super::{conn::pooled::PooledConnection, manager::PoolManager};
use crate::{
    bson::oid::ObjectId,
    cmap::PoolGeneration,
    error::{load_balanced_mode_mismatch, Error, ErrorKind, Redact, Result},
    event::cmap::{CmapEventEmitter, ConnectionCreatedEvent},
    options::ServerAddress,
    runtime::AsyncStream,
};
pub(crate) use command::{Command, RawCommandResponse, WriteErrorBody};
pub(crate) use stream_description::StreamDescription;

#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
use crate::options::Compressor;

/// User-facing information about a connection to the database.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionInfo {
    /// A driver-generated identifier that uniquely identifies the connection.
    pub id: u32,

    /// A server-generated identifier that uniquely identifies the connection. This may be used to
    /// correlate driver connections with server logs.
    pub server_id: Option<i64>,

    /// The address that the connection is connected to.
    pub address: ServerAddress,
}

/// A wrapper around Stream that contains all the CMAP information needed to maintain a connection.
#[derive_where(Debug)]
pub(crate) struct Connection {
    /// The stream this connection reads from and writes to.
    stream: BufStream<AsyncStream>,

    /// The cached stream description from the connection's handshake.
    pub(crate) stream_description: Option<StreamDescription>,

    /// Driver-generated ID for the connection.
    pub(crate) id: u32,

    /// The server-side ID for this connection.
    pub(crate) server_id: Option<i64>,

    /// The address of the server to which this connection connects.
    pub(crate) address: ServerAddress,

    /// The time at which this connection was created.
    pub(crate) time_created: Instant,

    /// Whether or not a command is currently being run on this connection. This is set to `true`
    /// right before sending bytes to the server and set back to `false` once a full response has
    /// been read.
    command_executing: bool,

    /// Stores a network error encountered while reading or writing. Once the connection has
    /// received an error, it should not be used again and will be closed upon check-in to the
    /// pool.
    error: Option<Error>,

    /// Whether the most recently received message included the moreToCome flag, indicating the
    /// server may send more responses without any additional requests. Attempting to send new
    /// messages on this connection while this value is true will return an error. This value
    /// will remain true until a server response does not include the moreToComeFlag.
    more_to_come: bool,

    /// The token callback for OIDC authentication.
    #[derive_where(skip)]
    pub(crate) oidc_token_gen_id: tokio::sync::Mutex<u32>,

    /// The compressor to use to compress outgoing messages.
    #[cfg(any(
        feature = "zstd-compression",
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))]
    pub(crate) compressor: Option<Compressor>,
}

impl Connection {
    /// Create a new connection.
    pub(crate) fn new(
        address: ServerAddress,
        stream: AsyncStream,
        id: u32,
        time_created: Instant,
    ) -> Self {
        Self {
            stream: BufStream::new(stream),
            stream_description: None,
            address,
            id,
            server_id: None,
            time_created,
            command_executing: false,
            error: None,
            more_to_come: false,
            oidc_token_gen_id: tokio::sync::Mutex::new(0),
            #[cfg(any(
                feature = "zstd-compression",
                feature = "zlib-compression",
                feature = "snappy-compression"
            ))]
            compressor: None,
        }
    }

    pub(crate) fn take(&mut self) -> Self {
        Self {
            stream: std::mem::replace(&mut self.stream, BufStream::new(AsyncStream::Null)),
            stream_description: self.stream_description.take(),
            address: self.address.clone(),
            id: self.id,
            server_id: self.server_id,
            time_created: self.time_created,
            command_executing: self.command_executing,
            error: self.error.take(),
            more_to_come: false,
            oidc_token_gen_id: tokio::sync::Mutex::new(0),
            #[cfg(any(
                feature = "zstd-compression",
                feature = "zlib-compression",
                feature = "snappy-compression"
            ))]
            compressor: self.compressor.clone(),
        }
    }

    pub(crate) fn address(&self) -> &ServerAddress {
        &self.address
    }

    /// Gets the connection's StreamDescription.
    pub(crate) fn stream_description(&self) -> Result<&StreamDescription> {
        self.stream_description.as_ref().ok_or_else(|| {
            ErrorKind::Internal {
                message: "Stream checked out but not handshaked".to_string(),
            }
            .into()
        })
    }

    /// Whether the connection is currently executing an operation.
    pub(super) fn is_executing(&self) -> bool {
        self.command_executing
    }

    /// Whether an error has been encountered on this connection.
    pub(super) fn has_errored(&self) -> bool {
        self.error.is_some()
    }

    pub(crate) async fn send_message_with_cancellation(
        &mut self,
        message: impl TryInto<Message, Error = impl Into<Error>>,
        cancellation_receiver: &mut broadcast::Receiver<()>,
    ) -> Result<RawCommandResponse> {
        tokio::select! {
            biased;

            // A lagged error indicates that more heartbeats failed than the channel's capacity
            // between checking out this connection and executing the operation. If this occurs,
            // then proceed with cancelling the operation. RecvError::Closed can be ignored, as
            // the sender (and by extension the connection pool) dropping does not indicate that
            // the operation should be cancelled.
            Ok(_) | Err(RecvError::Lagged(_)) = cancellation_receiver.recv() => {
                let error: Error = ErrorKind::ConnectionPoolCleared {
                    message: format!(
                        "Connection to {} interrupted due to server monitor timeout",
                        Redact(&self.address),
                    )
                }.into();
                self.error = Some(error.clone());
                Err(error)
            }
            // This future is not cancellation safe because it contains calls to methods that are
            // not cancellation safe (e.g. AsyncReadExt::read_exact). However, in the case that
            // this future is cancelled because a cancellation message was received, this
            // connection will be closed upon being returned to the pool, so any data loss on its
            // underlying stream is not an issue.
            result = self.send_message(message) => result,
        }
    }

    pub(crate) async fn send_message(
        &mut self,
        message: impl TryInto<Message, Error = impl Into<Error>>,
    ) -> Result<RawCommandResponse> {
        let message = message.try_into().map_err(Into::into)?;

        if self.more_to_come {
            return Err(Error::internal(format!(
                "attempted to send a new message to {} but moreToCome bit was set",
                Redact(self.address())
            )));
        }

        self.command_executing = true;

        let max_message_size = self.max_message_size_bytes();
        #[cfg(any(
            feature = "zstd-compression",
            feature = "zlib-compression",
            feature = "snappy-compression"
        ))]
        let write_result = match self.compressor {
            Some(ref compressor) if message.should_compress => {
                message
                    .write_op_compressed_to(&mut self.stream, compressor, max_message_size)
                    .await
            }
            _ => {
                message
                    .write_op_msg_to(&mut self.stream, max_message_size)
                    .await
            }
        };
        #[cfg(all(
            not(feature = "zstd-compression"),
            not(feature = "zlib-compression"),
            not(feature = "snappy-compression")
        ))]
        let write_result = message
            .write_op_msg_to(&mut self.stream, max_message_size)
            .await;

        if let Err(ref err) = write_result {
            self.error = Some(err.clone());
        }
        write_result?;

        let response_message_result = Message::read_from(&mut self.stream, max_message_size).await;
        self.command_executing = false;
        if let Err(ref err) = response_message_result {
            self.error = Some(err.clone());
        }

        let response_message = response_message_result?;
        self.more_to_come = response_message.flags.contains(MessageFlags::MORE_TO_COME);

        Ok(RawCommandResponse::new(
            self.address.clone(),
            response_message,
        ))
    }

    /// Receive the next message from the connection.
    /// This will return an error if the previous response on this connection did not include the
    /// moreToCome flag.
    pub(crate) async fn receive_message(&mut self) -> Result<RawCommandResponse> {
        if !self.more_to_come {
            return Err(Error::internal(format!(
                "attempted to stream response from connection to {} but moreToCome bit was not set",
                Redact(self.address())
            )));
        }

        self.command_executing = true;
        let response_message_result = Message::read_from(
            &mut self.stream,
            self.stream_description
                .as_ref()
                .map(|d| d.max_message_size_bytes),
        )
        .await;
        self.command_executing = false;
        if let Err(ref err) = response_message_result {
            self.error = Some(err.clone());
        }

        let response_message = response_message_result?;
        self.more_to_come = response_message.flags.contains(MessageFlags::MORE_TO_COME);

        Ok(RawCommandResponse::new(
            self.address.clone(),
            response_message,
        ))
    }

    /// Whether or not the previous command response indicated that the server may send
    /// more responses without another request.
    pub(crate) fn is_streaming(&self) -> bool {
        self.more_to_come
    }

    fn max_message_size_bytes(&self) -> Option<i32> {
        self.stream_description
            .as_ref()
            .map(|d| d.max_message_size_bytes)
    }
}

/// A handle to a pinned connection - the connection itself can be retrieved or returned to the
/// normal pool via this handle.
#[derive(Debug)]
pub(crate) struct PinnedConnectionHandle {
    id: u32,
    receiver: Arc<Mutex<mpsc::Receiver<PooledConnection>>>,
}

impl PinnedConnectionHandle {
    /// Make a new `PinnedConnectionHandle` that refers to the same connection as this one.
    /// Use with care and only when "lending" a handle in a way that can't be expressed as a
    /// normal borrow.
    pub(crate) fn replicate(&self) -> Self {
        Self {
            id: self.id,
            receiver: self.receiver.clone(),
        }
    }

    /// Retrieve the pinned connection.  Will fail if the connection has been unpinned or is still
    /// in use.
    pub(crate) async fn take_connection(&self) -> Result<PooledConnection> {
        use tokio::sync::mpsc::error::TryRecvError;
        let mut receiver = self.receiver.lock().await;
        let mut connection = match receiver.try_recv() {
            Ok(conn) => conn,
            Err(TryRecvError::Disconnected) => {
                return Err(Error::internal(format!(
                    "cannot take connection after unpin (id={})",
                    self.id
                )))
            }
            Err(TryRecvError::Empty) => {
                return Err(Error::internal(format!(
                    "cannot take in-use connection (id={})",
                    self.id
                )))
            }
        };
        connection.mark_pinned_in_use();
        Ok(connection)
    }

    pub(crate) fn id(&self) -> u32 {
        self.id
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct LoadBalancedGeneration {
    pub(crate) generation: u32,
    pub(crate) service_id: ObjectId,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum ConnectionGeneration {
    Normal(u32),
    LoadBalanced(Option<LoadBalancedGeneration>),
}

impl ConnectionGeneration {
    pub(crate) fn service_id(self) -> Option<ObjectId> {
        match self {
            ConnectionGeneration::LoadBalanced(Some(gen)) => Some(gen.service_id),
            _ => None,
        }
    }

    pub(crate) fn is_stale(self, current_generation: &PoolGeneration) -> bool {
        match (self, current_generation) {
            (ConnectionGeneration::Normal(cgen), PoolGeneration::Normal(pgen)) => cgen != *pgen,
            (ConnectionGeneration::LoadBalanced(cgen), PoolGeneration::LoadBalanced(gen_map)) => {
                if let Some(cgen) = cgen {
                    cgen.generation != *gen_map.get(&cgen.service_id).unwrap_or(&0)
                } else {
                    // In the event that an error occurred during handshake and no serviceId was
                    // returned, just ignore the error for SDAM purposes, since
                    // we won't know which serviceId to clear for.
                    false
                }
            }
            _ => load_balanced_mode_mismatch!(false),
        }
    }
}

impl From<LoadBalancedGeneration> for ConnectionGeneration {
    fn from(gen: LoadBalancedGeneration) -> Self {
        ConnectionGeneration::LoadBalanced(Some(gen))
    }
}

/// Struct encapsulating the information needed to establish a `Connection`.
///
/// Creating a `PendingConnection` contributes towards the total connection count of a pool, despite
/// not actually making a TCP connection to the pool's endpoint. This models a "pending" Connection
/// from the CMAP specification.
pub(crate) struct PendingConnection {
    pub(crate) id: u32,
    pub(crate) address: ServerAddress,
    pub(crate) generation: PoolGeneration,
    pub(crate) event_emitter: CmapEventEmitter,
    pub(crate) time_created: Instant,
    pub(crate) cancellation_receiver: Option<broadcast::Receiver<()>>,
}

impl PendingConnection {
    /// Helper to create a `ConnectionCreatedEvent` for the connection.
    pub(super) fn created_event(&self) -> ConnectionCreatedEvent {
        ConnectionCreatedEvent {
            address: self.address.clone(),
            connection_id: self.id,
        }
    }
}
