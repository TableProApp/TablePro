use crate::bson::oid::ObjectId;

use crate::{
    event::cmap::{CmapEvent, ConnectionCheckoutFailedReason, ConnectionClosedReason},
    trace::{
        TracingRepresentation,
        CONNECTION_TRACING_EVENT_TARGET,
        DEFAULT_MAX_DOCUMENT_LENGTH_BYTES,
    },
};

#[derive(Clone)]
pub(crate) struct ConnectionTracingEventEmitter {
    topology_id: ObjectId,
    max_document_length_bytes: usize,
}

impl ConnectionTracingEventEmitter {
    pub(crate) fn new(
        topology_id: ObjectId,
        max_document_length_bytes: Option<usize>,
    ) -> ConnectionTracingEventEmitter {
        Self {
            topology_id,
            max_document_length_bytes: max_document_length_bytes
                .unwrap_or(DEFAULT_MAX_DOCUMENT_LENGTH_BYTES),
        }
    }

    pub(crate) fn handle(&self, event: CmapEvent) {
        use CmapEvent::*;
        match event {
            PoolCreated(event) => {
                let options_ref = event.options.as_ref();
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    maxIdleTimeMS = options_ref.and_then(|o| o.max_idle_time.map(|m| m.as_millis())),
                    maxPoolSize = options_ref.and_then(|o| o.max_pool_size),
                    minPoolSize = options_ref.and_then(|o| o.min_pool_size),
                    "Connection pool created",
                );
            }
            PoolReady(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    "Connection pool ready",
                );
            }
            PoolCleared(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    serviceId = event.service_id.map(|id| id.tracing_representation()),
                    "Connection pool cleared",
                );
            }
            PoolClosed(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    "Connection pool closed",
                );
            }
            ConnectionCreated(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    driverConnectionId = event.connection_id,
                    "Connection created",
                );
            }
            ConnectionReady(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    driverConnectionId = event.connection_id,
                    durationMS = event.duration.as_millis(),
                    "Connection ready",
                );
            }
            ConnectionClosed(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    driverConnectionId = event.connection_id,
                    reason = event.reason.tracing_representation(),
                    error = event.error.map(|e| e.tracing_representation(self.max_document_length_bytes)),
                    "Connection closed",
                );
            }
            ConnectionCheckoutStarted(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    "Connection checkout started",
                );
            }
            ConnectionCheckoutFailed(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    reason = event.reason.tracing_representation(),
                    error = event.error.map(|e| e.tracing_representation(self.max_document_length_bytes)),
                    durationMS = event.duration.as_millis(),
                    "Connection checkout failed",
                );
            }
            ConnectionCheckedOut(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    driverConnectionId = event.connection_id,
                    durationMS = event.duration.as_millis(),
                    "Connection checked out",
                );
            }
            ConnectionCheckedIn(event) => {
                tracing::debug!(
                    target: CONNECTION_TRACING_EVENT_TARGET,
                    topologyId = self.topology_id.tracing_representation(),
                    serverHost = event.address.host().as_ref(),
                    serverPort = event.address.port_tracing_representation(),
                    driverConnectionId = event.connection_id,
                    "Connection checked in",
                );
            }
        }
    }
}

impl TracingRepresentation for ConnectionClosedReason {
    type Representation = &'static str;

    fn tracing_representation(&self) -> &'static str {
        match self {
            Self::Stale => "Connection became stale because the pool was cleared",
            Self::Idle => {
                "Connection has been available but unused for longer than the configured max idle \
                 time"
            }
            Self::Error => "An error occurred while using the connection",
            Self::Dropped => "Connection was dropped during an operation",
            Self::PoolClosed => "Connection pool was closed",
            #[cfg(test)]
            Self::Unset => "Unset",
        }
    }
}

impl TracingRepresentation for ConnectionCheckoutFailedReason {
    type Representation = &'static str;

    fn tracing_representation(&self) -> &'static str {
        match self {
            Self::Timeout => "Failed to establish a new connection within connectTimeoutMS",
            Self::ConnectionError => "An error occurred while trying to establish a new connection",
            #[cfg(test)]
            Self::Unset => "Unset",
        }
    }
}
