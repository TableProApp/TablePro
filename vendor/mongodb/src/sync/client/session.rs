use super::Client;
use crate::{bson::Document, client::session::ClusterTime, ClientSession as AsyncClientSession};

/// A MongoDB client session. This struct represents a logical session used for ordering sequential
/// operations. To create a `ClientSession`, call `start_session` on a
/// [`Client`](../struct.Client.html).
///
/// `ClientSession` instances are not thread safe or fork safe. They can only be used by one thread
/// or process at a time.
pub struct ClientSession {
    pub(crate) async_client_session: AsyncClientSession,
}

impl From<AsyncClientSession> for ClientSession {
    fn from(async_client_session: AsyncClientSession) -> Self {
        Self {
            async_client_session,
        }
    }
}

impl<'a> From<&'a mut ClientSession> for &'a mut AsyncClientSession {
    fn from(value: &'a mut ClientSession) -> &'a mut AsyncClientSession {
        &mut value.async_client_session
    }
}

impl ClientSession {
    pub(crate) fn new(async_client_session: AsyncClientSession) -> Self {
        Self {
            async_client_session,
        }
    }

    /// The client used to create this session.
    pub fn client(&self) -> Client {
        self.async_client_session.client().into()
    }

    /// The id of this session.
    pub fn id(&self) -> &Document {
        self.async_client_session.id()
    }

    /// The highest seen cluster time this session has seen so far.
    /// This will be `None` if this session has not been used in an operation yet.
    pub fn cluster_time(&self) -> Option<&ClusterTime> {
        self.async_client_session.cluster_time()
    }

    /// Set the cluster time to the provided one if it is greater than this session's highest seen
    /// cluster time or if this session's cluster time is `None`.
    pub fn advance_cluster_time(&mut self, to: &ClusterTime) {
        self.async_client_session.advance_cluster_time(to)
    }
}
