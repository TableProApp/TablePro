use crate::conformance::ConformanceEngine;

/// An engine whose editor session can hold a transaction open across
/// runs.
pub trait EditorTransactionEngine: ConformanceEngine {
    fn begin_sql(&self) -> String;

    fn commit_sql(&self) -> String;
}
