use std::fmt;

/// Where a connection was when it went away.
///
/// The phase decides what the app can say about the work: a loss while
/// idle costs nothing, a loss during a commit leaves the outcome
/// unknown until the server is asked again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LossPhase {
    Connect,
    Idle,
    Statement,
    Commit,
}

impl fmt::Display for LossPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Connect => "connecting",
            Self::Idle => "idle",
            Self::Statement => "running a statement",
            Self::Commit => "committing",
        })
    }
}
