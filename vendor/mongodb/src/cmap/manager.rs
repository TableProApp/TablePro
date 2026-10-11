use tokio::sync::mpsc;

use super::conn::pooled::PooledConnection;
use crate::{
    bson::oid::ObjectId,
    error::Error,
    runtime::{AcknowledgedMessage, AcknowledgmentReceiver},
    sdam::BroadcastMessage,
};

pub(super) fn channel() -> (PoolManager, ManagementRequestReceiver) {
    let (sender, receiver) = mpsc::unbounded_channel();
    (
        PoolManager { sender },
        ManagementRequestReceiver { receiver },
    )
}

/// Struct used to make management requests to the pool (e.g. checking in a connection).
/// A PoolManager will NOT keep a pool from going out of scope and closing.
#[derive(Clone, Debug)]
pub(crate) struct PoolManager {
    sender: mpsc::UnboundedSender<PoolManagementRequest>,
}

impl PoolManager {
    /// Lazily clear the pool.
    pub(super) async fn clear(&self, cause: Error, service_id: Option<ObjectId>) {
        let (message, acknowledgment_receiver) = AcknowledgedMessage::package(());
        if self
            .sender
            .send(PoolManagementRequest::Clear {
                _completion_handler: message,
                cause,
                service_id,
            })
            .is_ok()
        {
            acknowledgment_receiver.wait_for_acknowledgment().await;
        }
    }

    /// Mark the pool as "ready" as per the CMAP specification.
    pub(super) async fn mark_as_ready(&self) {
        let (message, listener) = AcknowledgedMessage::package(());
        if self
            .sender
            .send(PoolManagementRequest::MarkAsReady {
                completion_handler: message,
            })
            .is_ok()
        {
            let _ = listener.wait_for_acknowledgment().await;
        }
    }

    /// Check in the given connection to the pool. This returns an error containing the connection
    /// if the pool has been dropped. The connection's state will be transitioned to checked-in upon
    /// success.
    #[allow(clippy::result_large_err)]
    pub(crate) fn check_in(
        &self,
        connection: PooledConnection,
    ) -> std::result::Result<(), PooledConnection> {
        if let Err(request) = self
            .sender
            .send(PoolManagementRequest::CheckIn(Box::new(connection)))
        {
            let conn = request.0.unwrap_check_in();
            return Err(conn);
        }
        Ok(())
    }

    /// Notify the pool that establishing a connection failed.
    pub(super) fn handle_connection_failed(&self) {
        let _ = self
            .sender
            .send(PoolManagementRequest::HandleConnectionFailed);
    }

    /// Notify the pool that establishing a connection succeeded.
    pub(super) fn handle_connection_succeeded(&self, conn: ConnectionSucceeded) {
        let _ = self
            .sender
            .send(PoolManagementRequest::HandleConnectionSucceeded(conn));
    }

    pub(super) fn broadcast(&self, msg: BroadcastMessage) -> AcknowledgmentReceiver<()> {
        let (msg, ack) = AcknowledgedMessage::package(msg);
        let _ = self.sender.send(PoolManagementRequest::Broadcast(msg));
        ack
    }
}

#[derive(Debug)]
pub(super) struct ManagementRequestReceiver {
    pub(super) receiver: mpsc::UnboundedReceiver<PoolManagementRequest>,
}

impl ManagementRequestReceiver {
    pub(super) async fn recv(&mut self) -> Option<PoolManagementRequest> {
        self.receiver.recv().await
    }
}

#[derive(Debug)]
pub(super) enum PoolManagementRequest {
    /// Clear the pool, transitioning it to Paused.
    Clear {
        _completion_handler: AcknowledgedMessage<()>,
        cause: Error,
        service_id: Option<ObjectId>,
    },

    /// Mark the pool as Ready, allowing connections to be created and checked out.
    MarkAsReady {
        completion_handler: AcknowledgedMessage<()>,
    },

    /// Check in the given connection.
    CheckIn(Box<PooledConnection>),

    /// Update the pool based on the given establishment error.
    HandleConnectionFailed,

    /// Update the pool after a successful connection, optionally populating the pool
    /// with the successful connection.
    HandleConnectionSucceeded(ConnectionSucceeded),

    /// Handle a broadcast message.
    Broadcast(AcknowledgedMessage<BroadcastMessage>),
}

impl PoolManagementRequest {
    fn unwrap_check_in(self) -> PooledConnection {
        match self {
            PoolManagementRequest::CheckIn(conn) => *conn,
            _ => panic!("tried to unwrap checkin but got {self:?}"),
        }
    }
}

#[derive(Debug)]
pub(super) enum ConnectionSucceeded {
    ForPool(Box<PooledConnection>),
    Used { service_id: Option<ObjectId> },
}

impl ConnectionSucceeded {
    pub(super) fn service_id(&self) -> Option<ObjectId> {
        match self {
            ConnectionSucceeded::ForPool(conn) => conn.generation.service_id(),
            ConnectionSucceeded::Used { service_id, .. } => *service_id,
        }
    }
}
