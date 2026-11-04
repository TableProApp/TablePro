#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCategory {
    Configuration,
    Network,
    Tls,
    Authentication,
    ReadOnly,
    Server,
    Interrupted,
    Timeout,
    ConnectionLost,
    WriteOutcome,
    File,
    Busy,
    Internal,
}
