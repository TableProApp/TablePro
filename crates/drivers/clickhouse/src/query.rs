use super::{ROW_FORMAT, map_clickhouse_error};
use tablepro_core::DriverError;

/// Reads a `ROW_FORMAT` response one line at a time so the caller can
/// stop at `max_rows` without materialising the rest of the result.
pub(super) struct LineReader {
    cursor: clickhouse::query::BytesCursor,
    buf: Vec<u8>,
    consumed: usize,
    eof: bool,
}

impl LineReader {
    pub(super) fn new(cursor: clickhouse::query::BytesCursor) -> Self {
        Self {
            cursor,
            buf: Vec::new(),
            consumed: 0,
            eof: false,
        }
    }

    pub(super) async fn next_line(&mut self) -> Result<Option<Vec<u8>>, DriverError> {
        loop {
            if let Some(idx) = self.buf[self.consumed..].iter().position(|b| *b == b'\n') {
                let end = self.consumed + idx;
                let line = self.buf[self.consumed..end].to_vec();
                self.consumed = end + 1;
                return Ok(Some(line));
            }
            if self.eof {
                let rest = self.buf[self.consumed..].to_vec();
                self.consumed = self.buf.len();
                return Ok((!rest.is_empty()).then_some(rest));
            }
            match self.cursor.next().await.map_err(map_clickhouse_error)? {
                Some(chunk) => {
                    self.buf.drain(..self.consumed);
                    self.consumed = 0;
                    self.buf.extend_from_slice(&chunk);
                }
                None => self.eof = true,
            }
        }
    }
}

pub(super) fn parse_line<T: serde::de::DeserializeOwned>(line: &[u8]) -> Result<T, DriverError> {
    serde_json::from_slice(line).map_err(|e| DriverError::Internal(format!("clickhouse response parse: {e}")))
}

/// ClickHouse 24.x can append an exception to a partially streamed
/// `JSONCompactEachRowWithNamesAndTypes` response as a one-cell JSON row. Do
/// not let that terminal error masquerade as a successful data row.
pub(super) fn exception_row_message(raw: &[serde_json::Value]) -> Option<&str> {
    let [serde_json::Value::String(message)] = raw else {
        return None;
    };
    let remainder = message.strip_prefix("Code: ")?;
    let (code, detail) = remainder.split_once(". ")?;
    if code.parse::<u32>().is_err()
        || !detail.contains("DB::")
        || !detail.contains("Exception:")
        || !detail.contains(" (version ")
        || !detail.ends_with("))")
    {
        return None;
    }
    Some(message)
}

/// `query_id` is a caller-generated UUID, so `KILL QUERY` can name the
/// statement later. ClickHouse's HTTP interface accepts it as a request
/// parameter; the server rejects a duplicate, which is why each call
/// mints a fresh one.
pub(super) fn tag_query(query: clickhouse::query::Query, query_id: Option<&str>) -> clickhouse::query::Query {
    match query_id {
        Some(query_id) => query.with_setting("query_id", query_id),
        None => query,
    }
}

pub(super) fn new_query_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// ClickHouse has no per-request cancel channel, so the statement is
/// stopped by `KILL QUERY` naming the id the request was tagged with.
/// The id is a UUID rendered as hex and dashes, so it cannot carry SQL.
pub(super) async fn request_cancellation(client: &clickhouse::Client, query_id: &str) -> Result<(), DriverError> {
    let sql = format!("KILL QUERY WHERE query_id = '{query_id}'");
    let mut cursor = client
        .query(&sql)
        .fetch_bytes(ROW_FORMAT)
        .map_err(map_clickhouse_error)?;
    while cursor.next().await.map_err(map_clickhouse_error)?.is_some() {}
    Ok(())
}

/// ClickHouse reports an aborted statement as `QUERY_WAS_CANCELLED`
/// (code 394). The driver never populates `sqlstate`, so the code has
/// to be read out of the server's message.
pub(super) fn confirms_cancellation(error: &DriverError) -> bool {
    let DriverError::Query { message, .. } = error else {
        return false;
    };
    let lowered = message.to_lowercase();
    lowered.contains("code: 394") || lowered.contains("query was cancelled")
}
