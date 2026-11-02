use tablepro_core::{CommitResolution, CommitResolutionSupport, CommitToken, TableRef};

use crate::conformance::support::{CALL_DEADLINE, connect, expect, within, writable};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const CASE: &str = "commit_with_no_record_is_unresolvable";

/// Case 16: asked about a commit it keeps no record of, a driver answers
/// `Unresolvable` rather than failing the question. An engine with no
/// commit resolution at all keeps a record of nothing.
pub async fn commit_with_no_record_is_unresolvable<E: ConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    // Each engine is handed another engine's token, which it can never
    // have a record of.
    let token = match E::driver().capabilities().commit_resolution {
        CommitResolutionSupport::ServerTransactionStatus => CommitToken::ClickHouseQuery {
            query_ids: vec![uuid::Uuid::new_v4()],
            first_unconfirmed: 0,
            table: TableRef::unqualified("t"),
        },
        CommitResolutionSupport::QueryLog | CommitResolutionSupport::Unavailable => CommitToken::PostgresXid {
            xid: 1,
            legacy_txid: false,
        },
    };

    let answer = connection.resolve_commit(&token, within(CALL_DEADLINE)).await;

    expect(CASE, answer == Ok(CommitResolution::Unresolvable), || {
        format!("a commit with no record resolved as {answer:?}")
    })?;
    connection.close().await?;
    Ok(())
}
