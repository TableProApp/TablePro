use thiserror::Error;

#[derive(Debug, Error)]
pub enum DriverError {
    #[error("connection refused")]
    ConnectionRefused,

    #[error("authentication failed")]
    AuthFailed,

    #[error("TLS handshake failed: {0}")]
    Tls(String),

    #[error("query failed: {message}")]
    Query { message: String, sqlstate: Option<String> },

    #[error("connection closed unexpectedly")]
    Disconnected,

    #[error("connection is read-only; mutations are not permitted")]
    ReadOnly,

    #[error("driver internal error: {0}")]
    Internal(String),

    /// Returned by `Connection::execute_in_transaction` when one of the
    /// statements failed; the index identifies which statement (so the
    /// UI can highlight the offending row) and `source` carries the
    /// underlying driver error. The transaction has already been rolled
    /// back when this is returned — callers don't need to do cleanup.
    #[error("transaction failed at statement {statement_index}: {source}")]
    Transaction {
        statement_index: usize,
        source: Box<DriverError>,
    },
}
