use super::{FailureCause, LinkGeneration};

/// How a reconnect attempt ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReconnectResult {
    Connected(LinkGeneration),
    /// The server or the transport refused. Retrying changes nothing.
    Rejected(FailureCause),
    /// It did not get that far: a timeout, a refused socket, a DNS
    /// failure. Worth another try on a backoff.
    Failed,
}
