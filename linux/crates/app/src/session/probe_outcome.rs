use super::FailureCause;

/// What a health probe found. `classify` from a driver error lands with
/// the driver contract switch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProbeOutcome {
    Healthy,
    /// The connection answered, just not yet. It is alive, so this
    /// counts as healthy for the monitor's purposes.
    Busy,
    /// No answer in time. One of these is a hiccup; several in a row
    /// mean the connection is gone.
    Unresponsive,
    Lost,
    /// The server answered by refusing. Retrying the probe will not
    /// change that, but the connection itself is still up.
    Rejected(FailureCause),
}
