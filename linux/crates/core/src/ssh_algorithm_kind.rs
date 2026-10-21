use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SshAlgorithmKind {
    KeyExchange,
    HostKey,
    Cipher,
    Mac,
    Compression,
}

impl fmt::Display for SshAlgorithmKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::KeyExchange => "key exchange method",
            Self::HostKey => "host key type",
            Self::Cipher => "cipher",
            Self::Mac => "MAC",
            Self::Compression => "compression method",
        })
    }
}
