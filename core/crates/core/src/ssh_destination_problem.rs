use thiserror::Error;

use crate::SshDestinationPart;

/// What is wrong with an SSH host, username or jump host as typed. The
/// app words each one, so the variant carries values and no English.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SshDestinationProblem {
    #[error("the {part} is empty")]
    Empty { part: SshDestinationPart },

    #[error("the {part} starts with '-'")]
    LeadingDash { part: SshDestinationPart },

    #[error("the {part} contains spaces or control characters")]
    Whitespace { part: SshDestinationPart },

    #[error("the {part} contains {character:?}")]
    Character { part: SshDestinationPart, character: char },

    #[error("port 0 is not a valid port")]
    PortZero,

    #[error("{text:?} is not a port number")]
    NotAPort { text: String },

    #[error("an IPv6 host is missing its closing ']'")]
    UnclosedBracket,
}
