use crate::cmap::PoolGeneration;

/// Struct used to track the latest status of the pool.
#[derive(Clone, Debug)]
struct PoolStatus {
    /// The current generation of the pool.
    generation: PoolGeneration,
}

/// Create a channel for publishing and receiving updates to the pool's generation.
pub(super) fn channel(init: PoolGeneration) -> (PoolGenerationPublisher, PoolGenerationSubscriber) {
    let (sender, receiver) = tokio::sync::watch::channel(PoolStatus { generation: init });
    (
        PoolGenerationPublisher { sender },
        PoolGenerationSubscriber { receiver },
    )
}

/// Struct used to publish updates to the pool's generation.
#[derive(Debug)]
pub(super) struct PoolGenerationPublisher {
    sender: tokio::sync::watch::Sender<PoolStatus>,
}

impl PoolGenerationPublisher {
    /// Publish a new generation.
    pub(super) fn publish(&self, new_generation: PoolGeneration) {
        let new_status = PoolStatus {
            generation: new_generation,
        };

        // if nobody is listening, this will return an error, which we don't mind.
        let _: std::result::Result<_, _> = self.sender.send(new_status);
    }
}

/// Subscriber used to get the latest generation of the pool.
#[derive(Clone, Debug)]
pub(crate) struct PoolGenerationSubscriber {
    receiver: tokio::sync::watch::Receiver<PoolStatus>,
}

impl PoolGenerationSubscriber {
    /// Get a copy of the latest generation.
    pub(crate) fn generation(&self) -> PoolGeneration {
        self.receiver.borrow().generation.clone()
    }
}
