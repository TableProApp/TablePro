use tokio::sync::watch;

/// Handle to a worker. Once all handles have been dropped, the worker
/// will stop waiting for new requests.
#[derive(Debug, Clone)]
pub(crate) struct WorkerHandle {
    _receiver: watch::Receiver<()>,
}

impl WorkerHandle {
    #[cfg(test)]
    pub(crate) fn new_mocked() -> Self {
        let (s, _) = WorkerHandleListener::channel();
        s
    }
}

/// Listener used to determine when all handles have been dropped.
#[derive(Debug)]
pub(crate) struct WorkerHandleListener {
    sender: watch::Sender<()>,
}

impl WorkerHandleListener {
    /// Listen until all handles are dropped.
    /// This will not return until all handles are dropped, so make sure to only poll this via
    /// select or with a timeout.
    pub(crate) async fn wait_for_all_handle_drops(&self) {
        self.sender.closed().await
    }

    /// Returns whether there are handles that have not been dropped yet.
    pub(crate) fn is_alive(&self) -> bool {
        !self.sender.is_closed()
    }

    /// Constructs a new channel for for monitoring whether this worker still has references
    /// to it.
    pub(crate) fn channel() -> (WorkerHandle, WorkerHandleListener) {
        let (sender, receiver) = watch::channel(());
        (
            WorkerHandle {
                _receiver: receiver,
            },
            WorkerHandleListener { sender },
        )
    }
}
