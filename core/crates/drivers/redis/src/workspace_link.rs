use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use async_trait::async_trait;
use tablepro_core::{CallResource, DriverError, EngineStop, StopDelivery};

use crate::endpoint::RedisEndpoint;
use crate::link::Link;

/// The workspace's one link, shared by every sidebar listing and key
/// read. redis-rs multiplexes requests on it, and each of them is short
/// by construction (a `SCAN` or a range of one window), so no call waits
/// on another for long. A link found closed, or given up by a call, is
/// opened again on the next call.
pub(crate) struct WorkspaceLink {
    endpoint: Arc<RedisEndpoint>,
    slot: tokio::sync::Mutex<Option<(u64, Link)>>,
    generation: AtomicU64,
}

impl WorkspaceLink {
    pub(crate) fn new(endpoint: Arc<RedisEndpoint>, first: Link) -> Arc<Self> {
        Arc::new(Self {
            endpoint,
            slot: tokio::sync::Mutex::new(Some((0, first))),
            generation: AtomicU64::new(0),
        })
    }

    /// The live link, opened anew when the last one closed.
    async fn acquire(self: &Arc<Self>) -> Result<(u64, Link), DriverError> {
        let mut slot = self.slot.lock().await;
        if let Some((generation, link)) = slot.as_ref()
            && !link.is_closed()
        {
            return Ok((*generation, link.clone()));
        }
        let link = self.endpoint.open().await?;
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        *slot = Some((generation, link.clone()));
        Ok((generation, link))
    }

    /// Drop the link a call gave up on, unless another call already
    /// replaced it.
    fn forget(&self, generation: u64) {
        if let Ok(mut slot) = self.slot.try_lock()
            && slot.as_ref().is_some_and(|(held, _)| *held == generation)
        {
            *slot = None;
        }
    }

    pub(crate) async fn close(&self) {
        self.slot.lock().await.take();
    }
}

/// One call's hold on the workspace link, empty until the work fills
/// it, so the wait for a link runs under the call's deadline and cancel.
/// The link stays shared: a call that lost it, or was abandoned past the
/// cancel grace with a reply still owed, takes it out so the next call
/// opens a new one.
pub(crate) struct WorkspaceCall {
    owner: Arc<WorkspaceLink>,
    held: Option<(u64, Link)>,
    abandon: Arc<AtomicBool>,
}

impl WorkspaceCall {
    pub(crate) fn new(owner: Arc<WorkspaceLink>) -> Self {
        Self {
            owner,
            held: None,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) async fn link(&mut self) -> Result<Link, DriverError> {
        if let Some((_, link)) = &self.held {
            return Ok(link.clone());
        }
        let (generation, link) = self.owner.acquire().await?;
        self.held = Some((generation, link.clone()));
        Ok(link)
    }

    fn give_up(&mut self) {
        if let Some((generation, _)) = self.held.take() {
            self.owner.forget(generation);
        }
    }
}

impl Drop for WorkspaceCall {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.give_up();
        }
    }
}

impl CallResource for WorkspaceCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.give_up();
    }
}

/// A call on a link of its own, which closes with the call, so there is
/// nothing to hand back or take out of a pool.
pub(crate) struct OwnLink {
    abandon: Arc<AtomicBool>,
}

impl OwnLink {
    pub(crate) fn new() -> Self {
        Self {
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl CallResource for OwnLink {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(self) {}
}

/// A workspace read sends one bounded command at a time and stops
/// between them, so its stop travels with the work: nothing is sent to
/// the server, and a reply still on its way is read and dropped by
/// redis-rs.
pub(crate) struct BetweenCommands;

#[async_trait]
impl EngineStop for BetweenCommands {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::InBand
    }

    async fn stop(&self) -> Result<(), DriverError> {
        Ok(())
    }

    fn acknowledged(&self, _error: &DriverError) -> bool {
        false
    }
}
