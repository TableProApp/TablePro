use std::fmt;

/// What was busy. The app acts on both the same way, so this is a
/// value it words rather than a variant of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BusyReason {
    /// The server has no room for another connection, or the pool had
    /// no free slot in time.
    NoFreeConnection,
    /// Another connection to the database file held the lock a
    /// statement needed until the lock timeout ran out.
    FileLocked,
}

impl fmt::Display for BusyReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NoFreeConnection => "the server has no room for another connection",
            Self::FileLocked => "another connection holds a lock on the database file",
        })
    }
}
