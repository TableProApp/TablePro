use tablepro_core::export::{EncodeError, RenderError};
use tablepro_session::runtime::TaskFailure;
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
    /// Rows read so far for a document, which is written only once the
    /// last one is in.
    Progress {
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
    #[error("the read returned no result set")]
    NoResultSet,
    #[error(transparent)]
    Document(#[from] RenderError),
    /// A sheet is full and more rows are still coming, so how many there
    /// are in all is never read.
    #[error("a sheet holds {limit} rows, and the result has more")]
    SheetFull { limit: usize },
    #[error(transparent)]
    Task(#[from] TaskFailure),
}
