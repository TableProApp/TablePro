use super::FailureCause;

/// What the workspace banner says about a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionHealth {
    Online,
    /// Retrying on a backoff. `attempt` counts from 1 and drives the
    /// banner text.
    Reconnecting {
        attempt: u32,
    },
    /// The endpoint is unreachable, so retrying on a short backoff
    /// would only spin. The monitor rechecks on a long timer.
    Offline,
    /// Parked. Nothing retries until the user asks.
    Failed {
        cause: FailureCause,
    },
}

impl SessionHealth {
    pub fn is_online(&self) -> bool {
        matches!(self, Self::Online)
    }

    /// Whether the banner should be showing.
    pub fn needs_attention(&self) -> bool {
        !self.is_online()
    }
}
