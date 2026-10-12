use std::time::Duration;

use super::{LinkGeneration, Reachability};

/// Something the monitor should react to.
///
/// Everything that can wake the monitor arrives as one of these, so the
/// loop has a single input and the policy stays a pure function of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MonitorSignal {
    /// The user asked. This is the only signal that unparks a failed
    /// session.
    RetryNow,
    ConnectionLost {
        generation: LinkGeneration,
    },
    /// An operation ended in a way that says nothing about the
    /// connection itself, so the monitor checks rather than assuming.
    ProbeRequested {
        generation: LinkGeneration,
    },
    /// Real work went through, which is better evidence than any probe.
    OperationSucceeded {
        generation: LinkGeneration,
    },
    Reachability(Reachability),
    /// The machine came back from suspend. `slept` is how long it was
    /// gone, which decides whether the connection is worth probing.
    Resumed {
        slept: Duration,
    },
}
