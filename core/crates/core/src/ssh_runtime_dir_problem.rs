use std::io::ErrorKind;

use thiserror::Error;

/// Why the directory that holds the SSH control sockets cannot be used.
/// The app words each one; an I/O failure keeps only its kind, since
/// std's text is English.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SshRuntimeDirProblem {
    #[error("the directory belongs to another user")]
    OtherOwner,

    #[error("the path is not a directory")]
    NotADirectory,

    #[error("the directory mode is {mode:o}, expected 700")]
    OpenToOthers { mode: u32 },

    #[error("the path does not end in a directory name")]
    NoDirectoryName,

    #[error("a jump host's ssh cannot be given a path with spaces or shell characters")]
    NotAShellWord,

    #[error("{kind}")]
    Io { kind: ErrorKind },
}
