use super::{
    trace_or_log_enabled,
    TracingOrLogLevel,
    TracingRepresentation,
    SERVER_SELECTION_TRACING_EVENT_TARGET,
};
use crate::{
    bson::oid::ObjectId,
    error::Error,
    sdam::{SelectedServer, TopologyDescription},
    selection_criteria::SelectionCriteria,
    trace::DEFAULT_MAX_DOCUMENT_LENGTH_BYTES,
};
use std::time::{Duration, Instant};

impl TracingRepresentation for SelectionCriteria {
    type Representation = String;

    fn tracing_representation(&self) -> Self::Representation {
        self.to_string()
    }
}

impl TracingRepresentation for TopologyDescription {
    type Representation = String;

    fn tracing_representation(&self) -> Self::Representation {
        self.to_string()
    }
}

/// Type responsible for emitting server selection tracing events.
pub(crate) struct ServerSelectionTracingEventEmitter<'a> {
    topology_id: ObjectId,
    criteria: &'a SelectionCriteria,
    operation_name: &'a str,
    start_time: Instant,
    timeout: Duration,
    max_document_length_bytes: usize,
}

impl ServerSelectionTracingEventEmitter<'_> {
    pub(crate) fn new<'a>(
        topology_id: ObjectId,
        criteria: &'a SelectionCriteria,
        operation_name: &'a str,
        start_time: Instant,
        timeout: Duration,
        max_document_length_bytes: Option<usize>,
    ) -> ServerSelectionTracingEventEmitter<'a> {
        ServerSelectionTracingEventEmitter::<'a> {
            topology_id,
            criteria,
            operation_name,
            start_time,
            timeout,
            max_document_length_bytes: max_document_length_bytes
                .unwrap_or(DEFAULT_MAX_DOCUMENT_LENGTH_BYTES),
        }
    }

    pub(crate) fn emit_started_event(&self, topology_description: TopologyDescription) {
        if trace_or_log_enabled!(
            target: SERVER_SELECTION_TRACING_EVENT_TARGET,
            TracingOrLogLevel::Debug
        ) {
            tracing::debug!(
                target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                topologyId = self.topology_id.tracing_representation(),
                operation = self.operation_name,
                selector = self.criteria.tracing_representation(),
                topologyDescription = topology_description.tracing_representation(),
                "Server selection started"
            );
        }
    }

    pub(crate) fn emit_failed_event(
        &self,
        topology_description: &TopologyDescription,
        error: &Error,
    ) {
        if trace_or_log_enabled!(
            target: SERVER_SELECTION_TRACING_EVENT_TARGET,
            TracingOrLogLevel::Debug
        ) {
            tracing::debug!(
                target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                topologyId = self.topology_id.tracing_representation(),
                operation = self.operation_name,
                selector = self.criteria.tracing_representation(),
                topologyDescription = topology_description.tracing_representation(),
                failure = error.tracing_representation(self.max_document_length_bytes),
                "Server selection failed"
            );
        }
    }

    pub(crate) fn emit_succeeded_event(
        &self,
        topology_description: &TopologyDescription,
        server: &SelectedServer,
    ) {
        if trace_or_log_enabled!(
            target: SERVER_SELECTION_TRACING_EVENT_TARGET,
            TracingOrLogLevel::Debug
        ) {
            tracing::debug!(
                target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                topologyId = self.topology_id.tracing_representation(),
                operation = self.operation_name,
                selector = self.criteria.tracing_representation(),
                topologyDescription = topology_description.tracing_representation(),
                serverHost = server.address.host().as_ref(),
                serverPort = server.address.port_tracing_representation(),
                "Server selection succeeded"
            );
        }
    }

    pub(crate) fn emit_waiting_event(&self, topology_description: &TopologyDescription) {
        if trace_or_log_enabled!(
            target: SERVER_SELECTION_TRACING_EVENT_TARGET,
            TracingOrLogLevel::Info
        ) {
            let remaining_time = self
                .timeout
                .checked_sub(self.start_time.elapsed())
                .unwrap_or(Duration::ZERO);
            tracing::info!(
                target: SERVER_SELECTION_TRACING_EVENT_TARGET,
                topologyId = self.topology_id.tracing_representation(),
                operation = self.operation_name,
                selector = self.criteria.tracing_representation(),
                topologyDescription = topology_description.tracing_representation(),
                remainingTimeMS = remaining_time.as_millis(),
                "Waiting for suitable server to become available",
            );
        }
    }
}
