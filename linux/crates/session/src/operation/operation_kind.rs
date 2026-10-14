use tablepro_core::WriteKind;

/// What an operation does, which decides its deadline and whether it
/// may run again after the connection is replaced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OperationKind {
    Metadata,
    Page,
    Count,
    Save(WriteKind),
    Probe,
    Close,
    /// Every row of a read streamed to a file, on a connection of its
    /// own. It runs as long as the rows keep coming, and a second run
    /// would write the file twice.
    Export,
}

impl OperationKind {
    /// Reads only. Running one twice shows the same thing; running a
    /// save twice could write twice.
    pub fn is_replayable(self) -> bool {
        matches!(self, Self::Metadata | Self::Page | Self::Count)
    }
}
