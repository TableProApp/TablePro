use tokio::sync::mpsc;
use tokio_util::bytes::Bytes;

use crate::result_event::RunEnd;
use crate::transaction_state::TransactionState;

/// One message of the rows a `COPY ... FROM STDIN` reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopyInPiece {
    /// Bytes of the rows as the file holds them, cut anywhere.
    Data(Bytes),
    /// The rows ended. A source that closes without it gave up, and the
    /// copy is abandoned, never finished with the rows it has.
    End,
}

/// Where a session takes the rows of a copy from, a piece at a time.
pub type CopyInRows = mpsc::Receiver<CopyInPiece>;

#[derive(Debug, Clone, PartialEq)]
pub struct CopyInSummary {
    pub end: RunEnd,
    /// The rows the server took, from its `COPY n`. 0 unless the copy
    /// completed.
    pub rows: u64,
    pub transaction_state: TransactionState,
}
