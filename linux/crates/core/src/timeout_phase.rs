use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TimeoutPhase {
    Connect,
    Login,
    SshHandshake,
    SshChannelOpen,
    LockWait,
    Statement,
    Probe,
    CancelAcknowledgement,
}

impl fmt::Display for TimeoutPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Connect => "connect",
            Self::Login => "login",
            Self::SshHandshake => "SSH handshake",
            Self::SshChannelOpen => "SSH channel open",
            Self::LockWait => "lock wait",
            Self::Statement => "statement",
            Self::Probe => "probe",
            Self::CancelAcknowledgement => "cancel acknowledgement",
        })
    }
}
