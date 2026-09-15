/// Why a connection attempt will not succeed on a retry.
///
/// Each of these needs the user to change something, so the monitor
/// parks instead of burning a backoff loop against a password that is
/// wrong or a host key that changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureCause {
    Authentication,
    Tls,
    Configuration,
    HostKeyUnknown,
    HostKeyChanged,
}
