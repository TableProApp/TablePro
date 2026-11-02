use std::fmt;

/// Which part of an SSH destination a problem is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SshDestinationPart {
    Host,
    User,
}

impl fmt::Display for SshDestinationPart {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Host => "host",
            Self::User => "user",
        })
    }
}
