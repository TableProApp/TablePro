use std::fmt;

/// Which list of an SSH handshake had no algorithm both sides allow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SshAlgorithmKind {
    KeyExchange,
    HostKey,
    Cipher,
    Mac,
    Compression,
}

impl fmt::Display for SshAlgorithmKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::KeyExchange => "key exchange method",
            Self::HostKey => "host key type",
            Self::Cipher => "cipher",
            Self::Mac => "MAC",
            Self::Compression => "compression method",
        })
    }
}
