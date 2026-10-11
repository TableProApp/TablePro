use std::time::Duration;

use crate::bson::oid::ObjectId;

use crate::{client::options::ServerAddress, hello::HelloReply, sdam::ServerType};

/// Contains information about a given server in a format digestible by a connection.
#[derive(Debug, Default, Clone)]
pub(crate) struct StreamDescription {
    /// The address of the server.
    pub(crate) server_address: ServerAddress,

    /// The type of the server when the handshake occurred.
    pub(crate) initial_server_type: ServerType,

    /// The maximum wire version that the server understands.
    pub(crate) max_wire_version: Option<i32>,

    /// The minimum wire version that the server understands.
    #[allow(dead_code)]
    pub(crate) min_wire_version: Option<i32>,

    /// The supported authentication mechanisms that the server understands.
    pub(crate) sasl_supported_mechs: Option<Vec<String>>,

    /// How long sessions started on this server will stay alive without
    /// without executing an operation before the server kills them.
    pub(crate) logical_session_timeout: Option<Duration>,

    /// The maximum size of writes (excluding command overhead) that should be sent to the server.
    pub(crate) max_bson_object_size: i64,

    /// The maximum number of inserts, updates, or deletes that
    /// can be included in a write batch.  If more than this number of writes are included, the
    /// server cannot guarantee space in the response document to reply to the batch.
    pub(crate) max_write_batch_size: i64,

    /// Whether the server associated with this connection supports the `hello` command.
    pub(crate) hello_ok: bool,

    /// The maximum permitted size of a BSON wire protocol message.
    pub(crate) max_message_size_bytes: i32,

    /// If the connection is to a load balancer, the id of the selected backend.
    pub(crate) service_id: Option<ObjectId>,
}

impl StreamDescription {
    /// Constructs a new StreamDescription from a `HelloReply`.
    pub(crate) fn from_hello_reply(reply: &HelloReply) -> Self {
        Self {
            server_address: reply.server_address.clone(),
            initial_server_type: reply.command_response.server_type(),
            max_wire_version: reply.command_response.max_wire_version,
            min_wire_version: reply.command_response.min_wire_version,
            sasl_supported_mechs: reply.command_response.sasl_supported_mechs.clone(),
            logical_session_timeout: reply
                .command_response
                .logical_session_timeout_minutes
                .map(|mins| Duration::from_secs(mins * 60)),
            max_bson_object_size: reply.command_response.max_bson_object_size,
            // The defaulting to 100,000 is here because mongocryptd doesn't include this field in
            // hello replies; this should never happen when talking to a real server.
            // TODO RUST-1532 Remove the defaulting when mongocryptd support is dropped.
            max_write_batch_size: reply
                .command_response
                .max_write_batch_size
                .unwrap_or(100_000),
            hello_ok: reply.command_response.hello_ok.unwrap_or(false),
            max_message_size_bytes: reply.command_response.max_message_size_bytes,
            service_id: reply.command_response.service_id,
        }
    }

    /// Whether this StreamDescription supports retryable writes.
    pub(crate) fn supports_retryable_writes(&self) -> bool {
        self.initial_server_type != ServerType::Standalone
            && self.logical_session_timeout.is_some()
            && self.max_wire_version.is_some_and(|version| version >= 6)
    }
}
