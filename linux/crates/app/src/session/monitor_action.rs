/// What the monitor loop does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MonitorAction {
    Probe,
    Reconnect,
    /// Sleep until the policy's next deadline, or until a signal
    /// arrives.
    Wait,
    /// Sleep until a signal arrives. There is no deadline: only the
    /// user asking unparks this.
    Park,
}
