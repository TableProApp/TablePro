use crate::bson::oid::ObjectId;

use crate::{
    bson_util::{doc_err, rawdoc_to_json_str},
    event::command::raw::RawCommandEvent,
    trace::{TracingRepresentation, COMMAND_TRACING_EVENT_TARGET},
};

use super::DEFAULT_MAX_DOCUMENT_LENGTH_BYTES;

/// Type responsible for listening for command monitoring events and converting them to
/// and emitting them as tracing events.
pub(crate) struct CommandTracingEventEmitter {
    max_document_length_bytes: usize,
    topology_id: ObjectId,
}

impl CommandTracingEventEmitter {
    pub(crate) fn new(
        max_document_length_bytes: Option<usize>,
        topology_id: ObjectId,
    ) -> CommandTracingEventEmitter {
        CommandTracingEventEmitter {
            max_document_length_bytes: max_document_length_bytes
                .unwrap_or(DEFAULT_MAX_DOCUMENT_LENGTH_BYTES),
            topology_id,
        }
    }

    pub(crate) fn handle(&self, event: RawCommandEvent) {
        match event {
            RawCommandEvent::Started(event) => {
                tracing::debug!(
                    target: COMMAND_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    command = rawdoc_to_json_str(&event.command, self.max_document_length_bytes).unwrap_or_else(doc_err),
                    databaseName = event.db,
                    commandName = event.command_name,
                    requestId = event.request_id,
                    driverConnectionId = event.connection.id,
                    serverConnectionId = event.connection.server_id,
                    serverHost = event.connection.address.host().as_ref(),
                    serverPort = event.connection.address.port_tracing_representation(),
                    serviceId = event.service_id.map(|id| id.tracing_representation()),
                    "Command started"
                );
            }
            RawCommandEvent::Succeeded(event) => {
                tracing::debug!(
                    target: COMMAND_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    reply = rawdoc_to_json_str(&event.reply, self.max_document_length_bytes).unwrap_or_else(doc_err),
                    commandName = event.command_name,
                    requestId = event.request_id,
                    driverConnectionId = event.connection.id,
                    serverConnectionId = event.connection.server_id,
                    serverHost = event.connection.address.host().as_ref(),
                    serverPort = event.connection.address.port_tracing_representation(),
                    serviceId = event.service_id.map(|id| id.tracing_representation()),
                    durationMS = event.duration.as_millis(),
                    "Command succeeded"
                );
            }
            RawCommandEvent::Failed(event) => {
                tracing::debug!(
                    target: COMMAND_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    failure = event.failure.tracing_representation(self.max_document_length_bytes),
                    commandName = event.command_name,
                    requestId = event.request_id,
                    driverConnectionId = event.connection.id,
                    serverConnectionId = event.connection.server_id,
                    serverHost = event.connection.address.host().as_ref(),
                    serverPort = event.connection.address.port_tracing_representation(),
                    serviceId = event.service_id.map(|id| id.tracing_representation()),
                    durationMS = event.duration.as_millis(),
                    "Command failed"
                );
            }
        }
    }
}
