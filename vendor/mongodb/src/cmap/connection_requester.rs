use tokio::sync::{mpsc, oneshot};

use super::conn::pooled::PooledConnection;
use crate::{
    error::{Error, Result},
    runtime::{AsyncJoinHandle, WorkerHandle},
};

/// Returns a new requester/receiver pair.
pub(super) fn channel(handle: WorkerHandle) -> (ConnectionRequester, ConnectionRequestReceiver) {
    let (sender, receiver) = mpsc::unbounded_channel();
    (
        ConnectionRequester {
            sender,
            _handle: handle,
        },
        ConnectionRequestReceiver { receiver },
    )
}

/// Handle for requesting Connections from the pool.
/// This requester will keep the pool alive. Once all requesters have been dropped,
/// the pool will stop servicing requests, drop its available connections, and close.
#[derive(Clone, Debug)]
pub(super) struct ConnectionRequester {
    sender: mpsc::UnboundedSender<ConnectionRequest>,
    _handle: WorkerHandle,
}

impl ConnectionRequester {
    /// Request a connection from the pool that owns the receiver end of this requester.
    pub(super) async fn request(&self) -> ConnectionRequestResult {
        let (sender, receiver) = oneshot::channel();

        // this only errors if the receiver end is dropped, which can't happen because
        // we own a handle to the worker, keeping it alive.
        self.sender
            .send(ConnectionRequest {
                sender,
                warm_pool: false,
            })
            .unwrap();

        // similarly, the receiver only returns an error if the sender is dropped, which
        // can't happen due to the handle.
        receiver.await.unwrap()
    }

    pub(super) fn weak(&self) -> WeakConnectionRequester {
        WeakConnectionRequester {
            sender: self.sender.clone(),
        }
    }
}

/// Handle for requesting Connections from the pool.  This does *not* keep the
/// pool alive.
#[derive(Clone, Debug)]
pub(super) struct WeakConnectionRequester {
    sender: mpsc::UnboundedSender<ConnectionRequest>,
}

impl WeakConnectionRequester {
    pub(super) async fn request_warm_pool(&self) -> Option<ConnectionRequestResult> {
        let (sender, receiver) = oneshot::channel();
        if self
            .sender
            .send(ConnectionRequest {
                sender,
                warm_pool: true,
            })
            .is_err()
        {
            return None;
        }
        receiver.await.ok()
    }
}

/// Receiving end of a given ConnectionRequester.
#[derive(Debug)]
pub(super) struct ConnectionRequestReceiver {
    receiver: mpsc::UnboundedReceiver<ConnectionRequest>,
}

impl ConnectionRequestReceiver {
    pub(super) async fn recv(&mut self) -> Option<ConnectionRequest> {
        self.receiver.recv().await
    }
}

/// Struct encapsulating a request for a connection.
#[derive(Debug)]
pub(super) struct ConnectionRequest {
    sender: oneshot::Sender<ConnectionRequestResult>,
    warm_pool: bool,
}

impl ConnectionRequest {
    /// Respond to the connection request, either with a pooled connection or one that is
    /// establishing asynchronously.
    pub(super) fn fulfill(
        self,
        result: ConnectionRequestResult,
    ) -> std::result::Result<(), ConnectionRequestResult> {
        self.sender.send(result)
    }

    pub(super) fn is_warm_pool(&self) -> bool {
        self.warm_pool
    }
}

#[derive(Debug)]
pub(super) enum ConnectionRequestResult {
    /// A connection that was already established and was simply checked out of the pool.
    Pooled(Box<PooledConnection>),

    /// A new connection in the process of being established.
    /// The handle can be awaited upon to receive the established connection.
    Establishing(AsyncJoinHandle<Result<PooledConnection>>),

    /// The request was rejected because the pool was cleared before it could
    /// be fulfilled. The error that caused the pool to be cleared is returned.
    PoolCleared(Error),

    /// The request set `warm_pool: true` and the pool has reached `min_pool_size`.
    PoolWarmed,
}

impl ConnectionRequestResult {
    pub(super) fn unwrap_pooled_connection(self) -> PooledConnection {
        match self {
            ConnectionRequestResult::Pooled(c) => *c,
            _ => panic!("attempted to unwrap pooled connection when was establishing"),
        }
    }
}
