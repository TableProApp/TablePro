use crate::conformance::ConformanceEngine;

/// An engine whose workspace connection is a pool with a fixed size.
pub trait PooledConformanceEngine: ConformanceEngine {
    /// The size the driver gives its pool, taken from the driver's own
    /// exported constant: a pool library's default depends on the host's
    /// core count, so only the driver's number is reliable.
    const WORKSPACE_POOL_MAX_SIZE: usize;
}
