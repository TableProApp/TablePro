use std::time::Duration;

use crate::{
    bson::{rawdoc, RawDocumentBuf},
    bson_compat::cstr,
    error::Error,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::{
    bson::{doc, oid::ObjectId, DateTime, Document},
    client::{
        options::{ServerAddress, ServerApi},
        ClusterTime,
    },
    cmap::{Command, Connection},
    error::Result,
    sdam::{ServerType, TopologyVersion},
    selection_criteria::TagSet,
};

/// The legacy version of the `hello` command which was deprecated in 5.0.
/// To limit usages of the legacy name in the codebase, this constant should be used
/// wherever possible.
pub(crate) const LEGACY_HELLO_COMMAND_NAME: &str = "isMaster";
pub(crate) const LEGACY_HELLO_COMMAND_NAME_CSTR: &crate::bson_compat::CStr = cstr!("isMaster");
pub(crate) const LEGACY_HELLO_COMMAND_NAME_LOWERCASE: &str = "ismaster";

#[derive(Debug, Clone, Copy)]
pub(crate) struct AwaitableHelloOptions {
    pub(crate) topology_version: TopologyVersion,
    pub(crate) max_await_time: Duration,
}

/// Construct a hello or legacy hello command, depending on the circumstances.
///
/// If an API version is provided or `load_balanced` is true, `hello` will be used.
/// If the server indicated `helloOk: true`, then `hello` will also be used.
/// Otherwise, legacy hello will be used, and if it's unknown whether the server supports hello,
/// the command also will contain `helloOk: true`.
pub(crate) fn hello_command(
    server_api: Option<&ServerApi>,
    load_balanced: Option<bool>,
    hello_ok: Option<bool>,
    awaitable_options: Option<AwaitableHelloOptions>,
) -> Command {
    let (mut body, command_name) = if server_api.is_some()
        || matches!(load_balanced, Some(true))
        || matches!(hello_ok, Some(true))
    {
        (rawdoc! { "hello": 1 }, "hello")
    } else {
        let mut body = rawdoc! { LEGACY_HELLO_COMMAND_NAME_CSTR: 1 };
        if hello_ok.is_none() {
            body.append(cstr!("helloOk"), true);
        }
        (body, LEGACY_HELLO_COMMAND_NAME)
    };

    body.append(cstr!("backpressure"), "2");

    if let Some(opts) = awaitable_options {
        body.append(cstr!("topologyVersion"), opts.topology_version);
        body.append(
            cstr!("maxAwaitTimeMS"),
            opts.max_await_time
                .as_millis()
                .try_into()
                .unwrap_or(i64::MAX),
        );
    }

    let mut command = Command::new_raw(command_name, "admin", body);
    if let Some(server_api) = server_api {
        command.set_server_api(server_api);
    }
    command.exhaust_allowed = awaitable_options.is_some();
    command
}

/// Execute a hello or legacy hello command.
pub(crate) async fn run_hello(
    conn: &mut Connection,
    command: Command,
    mut cancellation_receiver: Option<broadcast::Receiver<()>>,
) -> Result<HelloReply> {
    let response = match cancellation_receiver {
        Some(ref mut cancellation_receiver) => {
            conn.send_message_with_cancellation(command, cancellation_receiver)
                .await
        }
        None => conn.send_message(command).await,
    }
    .map_err(Error::with_backpressure_labels)?;
    response.into_hello_reply()
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct HelloReply {
    pub(crate) server_address: ServerAddress,
    pub(crate) command_response: HelloCommandResponse,
    pub(crate) raw_command_response: RawDocumentBuf,
    pub(crate) cluster_time: Option<ClusterTime>,
}

/// The response to a `hello` command.
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/reference/command/hello/) for more details.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HelloCommandResponse {
    /// Whether the server is writable. If true, this instance is a primary in a replica set, a
    /// mongos instance, or a standalone mongod.
    pub is_writable_primary: Option<bool>,

    #[serde(rename = "ismaster")]
    /// Legacy name for `is_writable_primary` field.
    pub is_master: Option<bool>,

    /// Whether or not the server supports using the `hello` command for monitoring instead
    /// of the legacy hello command.
    pub hello_ok: Option<bool>,

    /// The list of all hosts.
    pub hosts: Option<Vec<String>>,

    /// The list of all passives in a replica set.
    pub passives: Option<Vec<String>>,

    /// The list of all arbiters in a replica set.
    pub arbiters: Option<Vec<String>>,

    /// An optional message. This contains the value "isdbgrid" when returned from a mongos.
    pub msg: Option<String>,

    /// The address of the server that returned this `HelloCommandResponse`.
    pub me: Option<String>,

    #[serde(rename = "compression")]
    /// The list of compatible compressors that the server returned.
    pub compressors: Option<Vec<String>>,

    /// The current replica set config version.
    pub set_version: Option<i32>,

    /// The name of the current replica set.
    pub set_name: Option<String>,

    /// Whether the server is hidden.
    pub hidden: Option<bool>,

    /// Whether the server is a secondary.
    pub secondary: Option<bool>,

    /// Whether the server is an arbiter.
    pub arbiter_only: Option<bool>,

    #[serde(rename = "isreplicaset")]
    /// Whether the server is a replica set.
    pub is_replica_set: Option<bool>,

    /// The time in minutes that a session remains active after its most recent use.
    #[serde(default, with = "crate::bson_util::option_u64_as_i64")]
    pub logical_session_timeout_minutes: Option<u64>,

    /// Optime and date information for the server's most recent write operation.
    pub last_write: Option<LastWrite>,

    /// The minimum wire version that the server supports.
    pub min_wire_version: Option<i32>,

    /// The maximum wire version that the server supports.
    pub max_wire_version: Option<i32>,

    /// User-defined tags for a replica set member.
    pub tags: Option<TagSet>,

    /// A unique identifier for each election.
    pub election_id: Option<ObjectId>,

    /// The address of current primary member of the replica set.
    pub primary: Option<String>,

    /// A list of SASL mechanisms used to create the user's credential(s).
    pub sasl_supported_mechs: Option<Vec<String>>,

    /// The reply to speculative authentication done in the authentication handshake.
    pub speculative_authenticate: Option<Document>,

    /// The maximum permitted size of a BSON object in bytes.
    pub max_bson_object_size: i64,

    /// The maximum number of write operations permitted in a write batch.
    pub max_write_batch_size: Option<i64>,

    /// If the connection is to a load balancer, the id of the selected backend.
    pub service_id: Option<ObjectId>,

    /// For internal use.
    pub topology_version: Option<TopologyVersion>,

    /// The maximum permitted size of a BSON wire protocol message.
    pub max_message_size_bytes: i32,

    /// The server-generated ID for the connection the "hello" command was run on.
    pub connection_id: Option<i64>,
}

impl HelloCommandResponse {
    pub(crate) fn server_type(&self) -> ServerType {
        if self.msg.as_deref() == Some("isdbgrid") {
            ServerType::Mongos
        } else if self.set_name.is_some() {
            if self.hidden == Some(true) {
                ServerType::RsOther
            } else if self.is_writable_primary == Some(true) || self.is_master == Some(true) {
                ServerType::RsPrimary
            } else if self.secondary == Some(true) {
                ServerType::RsSecondary
            } else if self.arbiter_only == Some(true) {
                ServerType::RsArbiter
            } else {
                ServerType::RsOther
            }
        } else if self.is_replica_set == Some(true) {
            ServerType::RsGhost
        } else {
            ServerType::Standalone
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LastWrite {
    pub last_write_date: DateTime,
}
