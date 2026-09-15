/// What the app needs to ask the server whether a commit landed.
///
/// A connection lost between COMMIT and its acknowledgement leaves the
/// outcome unknown. Every engine that can answer the question later
/// needs something from before the loss, so it is taken during the
/// write and kept until the answer arrives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitToken {
    /// The transaction id PostgreSQL gives out inside the transaction,
    /// which `pg_xact_status` reads back afterwards. `legacy_txid` says
    /// the id came from `txid_current` on a server before 13.
    PostgresXid { xid: u64, legacy_txid: bool },
    /// ClickHouse has no transactions, so the token is the query ids
    /// that were sent, and how many of them are known to have finished.
    ClickHouseQuery {
        query_ids: Vec<uuid::Uuid>,
        first_unconfirmed: usize,
    },
}

/// What the server said when asked about a commit whose outcome was
/// unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CommitResolution {
    Applied,
    NotApplied,
    PartiallyApplied,
    /// The work is still going, so the answer is not final yet.
    StillRunning,
    /// The server cannot answer: the record aged out, or the engine
    /// never had one.
    Unresolvable,
}
