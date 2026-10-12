use clickhouse::query::BytesCursor;
use tablepro_core::DriverError;
use tokio::io::AsyncBufReadExt;

use crate::errors::map_io_error;

/// A response body read one `\n`-terminated line at a time, so a caller
/// can stop at a row limit without reading the rest of the result.
pub(crate) struct LineReader {
    cursor: BytesCursor,
    line: Vec<u8>,
}

impl LineReader {
    pub(crate) fn new(cursor: BytesCursor) -> Self {
        Self {
            cursor,
            line: Vec::new(),
        }
    }

    /// The next line, without its terminator, or `None` at the end.
    ///
    /// Safe to use in `select!`: `read_until` appends to the buffer, so a
    /// read cut short keeps what it had and the next call carries on.
    pub(crate) async fn next_line(&mut self) -> Result<Option<Vec<u8>>, DriverError> {
        self.cursor
            .read_until(b'\n', &mut self.line)
            .await
            .map_err(map_io_error)?;
        if self.line.is_empty() {
            return Ok(None);
        }
        let mut line = std::mem::take(&mut self.line);
        if line.last() == Some(&b'\n') {
            line.pop();
        }
        Ok(Some(line))
    }

    /// The `X-ClickHouse-Summary` the server sent with the headers.
    pub(crate) fn written_rows(&self) -> Option<u64> {
        self.cursor.summary().and_then(clickhouse::QuerySummary::written_rows)
    }
}
