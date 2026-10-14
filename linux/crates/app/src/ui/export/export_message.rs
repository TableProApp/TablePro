use tablepro_core::export::{EncodeError, RenderError};
use thiserror::Error;

/// What the producer hands the writer on the GTK thread.
#[derive(Debug)]
pub(crate) enum ExportMessage {
    /// Encoded bytes, and how many rows the file holds once they are
    /// written.
    Chunk {
        bytes: Vec<u8>,
        rows: u64,
    },
    Failed(ExportStreamFailure),
    Finished {
        rows: u64,
    },
}

/// Why the rows could not be turned into the file's bytes.
#[derive(Debug, Error)]
pub(crate) enum ExportStreamFailure {
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error("the statement returned more than one result set")]
    MultipleResultSets,
    #[error(transparent)]
    Document(#[from] RenderError),
}
