use tablepro_core::{CommitResolution, CommitToken, DriverError};

use crate::metadata::{decode_error, text_rows};
use crate::workspace_call::{ReadOp, read_op};

/// Ask the server what became of the transaction a lost COMMIT named.
pub(crate) fn resolve_op(token: &CommitToken) -> Result<ReadOp<CommitResolution>, DriverError> {
    let CommitToken::PostgresXid { xid, legacy_txid } = token else {
        return Ok(read_op(|_| Box::pin(async { Ok(CommitResolution::Unresolvable) })));
    };
    let sql = if *legacy_txid {
        "SELECT txid_status($1::text::int8)::text"
    } else {
        "SELECT pg_xact_status($1::text::xid8)::text"
    };
    let xid = xid.to_string();
    Ok(read_op(move |client| {
        Box::pin(async move {
            let rows = text_rows(client, sql, &[&xid]).await?;
            let status: Option<String> = match rows.first() {
                Some(row) => row.try_get(0).map_err(decode_error("pg_xact_status"))?,
                None => None,
            };
            Ok(resolution(status.as_deref()))
        })
    }))
}

/// `committed`, `aborted` and `in progress` are final answers; NULL means
/// the record has aged out of the commit log.
fn resolution(status: Option<&str>) -> CommitResolution {
    match status {
        Some("committed") => CommitResolution::Applied,
        Some("aborted") => CommitResolution::NotApplied,
        Some("in progress") => CommitResolution::StillRunning,
        _ => CommitResolution::Unresolvable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_servers_answers_map_to_resolutions() {
        assert_eq!(resolution(Some("committed")), CommitResolution::Applied);
        assert_eq!(resolution(Some("aborted")), CommitResolution::NotApplied);
        assert_eq!(resolution(Some("in progress")), CommitResolution::StillRunning);
        assert_eq!(resolution(None), CommitResolution::Unresolvable);
    }
}
