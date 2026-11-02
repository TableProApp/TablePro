use std::time::Duration;

use tablepro_core::meta::{ObjectInfo, SchemaInfo};

use super::{ConnectRequest, ConnectionMetadata};
use crate::link::{CloseReport, EstablishedConnection};

/// A connection that worked, with its first catalog, waiting to be
/// adopted or thrown away.
///
/// `must_use` because dropping one leaves its close to whenever the last
/// reference goes; `discard` closes it under its deadline instead.
#[must_use]
pub struct PendingSession {
    request: ConnectRequest,
    established: EstablishedConnection,
    schemas: Vec<SchemaInfo>,
    objects: Vec<ObjectInfo>,
    close_timeout: Duration,
}

pub(crate) struct PendingParts {
    pub request: ConnectRequest,
    pub established: EstablishedConnection,
    pub schemas: Vec<SchemaInfo>,
    pub objects: Vec<ObjectInfo>,
    pub close_timeout: Duration,
}

impl PendingSession {
    pub(crate) fn new(
        request: ConnectRequest,
        established: EstablishedConnection,
        schemas: Vec<SchemaInfo>,
        objects: Vec<ObjectInfo>,
        close_timeout: Duration,
    ) -> Self {
        Self {
            request,
            established,
            schemas,
            objects,
            close_timeout,
        }
    }

    pub fn metadata(&self) -> &ConnectionMetadata {
        &self.request.metadata
    }

    pub fn request(&self) -> &ConnectRequest {
        &self.request
    }

    pub fn established(&self) -> &EstablishedConnection {
        &self.established
    }

    pub fn schemas(&self) -> &[SchemaInfo] {
        &self.schemas
    }

    pub fn objects(&self) -> &[ObjectInfo] {
        &self.objects
    }

    /// Close the connection, for an attempt that lost the race or a Test
    /// button that only wanted to know it works. The SSH master ends
    /// with the last reference to its session.
    pub async fn discard(self) -> CloseReport {
        match tokio::time::timeout(self.close_timeout, self.established.connection.close()).await {
            Ok(Ok(())) => CloseReport::Closed,
            Ok(Err(error)) => CloseReport::CloseFailed(error),
            Err(_) => CloseReport::Abandoned,
        }
    }

    pub(crate) fn into_parts(self) -> PendingParts {
        PendingParts {
            request: self.request,
            established: self.established,
            schemas: self.schemas,
            objects: self.objects,
            close_timeout: self.close_timeout,
        }
    }
}

impl std::fmt::Debug for PendingSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingSession")
            .field("request", &self.request)
            .field("established", &self.established)
            .finish_non_exhaustive()
    }
}
