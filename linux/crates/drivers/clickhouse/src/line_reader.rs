use clickhouse::query::BytesCursor;
use tablepro_core::DriverError;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt};

use crate::errors::map_io_error;

/// What a response body yields next.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Line {
    /// One line, without its terminator.
    Complete(Vec<u8>),
    /// The line ran past the limit without ending.
    TooLong,
    End,
}

/// A response body read one `\n`-terminated line at a time, so a caller
/// can stop at a row limit without reading the rest of the result.
pub(crate) struct LineReader<R = BytesCursor> {
    cursor: R,
    line: Vec<u8>,
}

impl<R: AsyncBufRead + Unpin> LineReader<R> {
    pub(crate) fn new(cursor: R) -> Self {
        Self {
            cursor,
            line: Vec::new(),
        }
    }

    /// The next line, which may hold at most `limit` bytes.
    ///
    /// A body in a format with no line breaks, such as RowBinary, is one
    /// endless line, so without the limit it would be buffered until the
    /// process ran out of memory. At most one byte past the limit is ever
    /// held.
    ///
    /// Safe to use in `select!`: `read_until` appends to the buffer, so a
    /// read cut short keeps what it had and the next call carries on.
    pub(crate) async fn next_line(&mut self, limit: usize) -> Result<Line, DriverError> {
        let room = limit.saturating_add(1).saturating_sub(self.line.len());
        (&mut self.cursor)
            .take(u64::try_from(room).unwrap_or(u64::MAX))
            .read_until(b'\n', &mut self.line)
            .await
            .map_err(map_io_error)?;
        if self.line.last() == Some(&b'\n') {
            let mut line = std::mem::take(&mut self.line);
            line.pop();
            return Ok(Line::Complete(line));
        }
        if self.line.len() > limit {
            return Ok(Line::TooLong);
        }
        if self.line.is_empty() {
            return Ok(Line::End);
        }
        Ok(Line::Complete(std::mem::take(&mut self.line)))
    }
}

impl LineReader<BytesCursor> {
    /// The `X-ClickHouse-Summary` the server sent with the headers.
    pub(crate) fn written_rows(&self) -> Option<u64> {
        self.cursor.summary().and_then(clickhouse::QuerySummary::written_rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn lines(body: &[u8], limit: usize) -> Vec<Line> {
        let mut reader = LineReader::new(body);
        let mut lines = Vec::new();
        loop {
            let line = reader.next_line(limit).await.expect("a line");
            let last = matches!(line, Line::End | Line::TooLong);
            lines.push(line);
            if last {
                return lines;
            }
        }
    }

    #[tokio::test]
    async fn lines_split_on_newlines_and_the_last_needs_none() {
        assert_eq!(
            lines(b"[1]\n[22]\n[3]", 4).await,
            vec![
                Line::Complete(b"[1]".to_vec()),
                Line::Complete(b"[22]".to_vec()),
                Line::Complete(b"[3]".to_vec()),
                Line::End,
            ]
        );
        assert_eq!(lines(b"", 4).await, vec![Line::End]);
    }

    #[tokio::test]
    async fn a_line_past_the_limit_is_refused_whether_or_not_it_ends() {
        assert_eq!(
            lines(b"[1]\n12345\n", 4).await,
            vec![Line::Complete(b"[1]".to_vec()), Line::TooLong]
        );
        assert_eq!(lines(b"12345", 4).await, vec![Line::TooLong]);
    }

    #[tokio::test]
    async fn an_endless_line_buffers_no_more_than_one_byte_past_the_limit() {
        let endless = tokio::io::BufReader::new(tokio::io::repeat(b'x'));
        let mut reader = LineReader::new(endless);

        assert_eq!(reader.next_line(1024).await.expect("a line"), Line::TooLong);
        assert_eq!(reader.line.len(), 1025);
    }
}
