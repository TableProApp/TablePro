use tablepro_core::value::UndecodableReason;

/// Why a binary value could not be read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WireError {
    /// The bytes are not what the type's binary form allows.
    Malformed,
    /// The bytes are well formed, and the value does not fit what the app
    /// can hold.
    OutOfRange,
}

impl WireError {
    pub(crate) fn reason(self) -> UndecodableReason {
        match self {
            Self::Malformed => UndecodableReason::InvalidEncoding,
            Self::OutOfRange => UndecodableReason::OutOfRange,
        }
    }
}
