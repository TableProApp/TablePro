use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use async_trait::async_trait;

use crate::error::DriverError;

/// What an engine's own stop addresses.
///
/// `Connection` means the stop names the physical connection rather
/// than the statement, as PostgreSQL's cancel request does with a
/// backend pid and MySQL's KILL QUERY does with a connection id. Such a
/// stop can arrive late and hit whatever that connection runs next, so
/// a connection it may still be chasing never goes back to the pool.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StopScope {
    Statement,
    Connection,
}

/// How a stop reaches the server.
///
/// `InBand` means the running request carries it, so nothing else has
/// to be sent and nothing can arrive late.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StopDelivery {
    OutOfBand(StopScope),
    InBand,
}

/// The engine's own way of stopping work already sent.
#[async_trait]
pub trait EngineStop: Send + Sync + 'static {
    fn delivery(&self) -> StopDelivery;

    /// Send the stop. Called at most once, and only for
    /// `OutOfBand` delivery.
    async fn stop(&self) -> Result<(), DriverError>;

    /// Whether this error is the engine acknowledging the stop rather
    /// than a failure of its own.
    fn acknowledged(&self, error: &DriverError) -> bool;
}

/// A connection held for the duration of one call.
///
/// The flag is what a pool's recycle checks, so a connection whose work
/// was abandoned is rejected instead of handed to the next caller with
/// a half-read result still on the wire.
pub trait CallResource: Send + 'static {
    fn abandon_flag(&self) -> Arc<AtomicBool>;

    /// Take the connection out of its pool and close it.
    fn discard(self);
}
