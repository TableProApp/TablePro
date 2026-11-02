use std::sync::Arc;

use clickhouse::query::{BytesCursor, Query};
use tablepro_core::column::ResultColumn;
use tablepro_core::{DriverError, Value};
use tokio::io::AsyncBufRead;

use crate::cell_seed::CellPlan;
use crate::clickhouse_type::ClickHouseType;
use crate::errors::map_error;
use crate::line_reader::{Line, LineReader};
use crate::row_seed::decode_row;

/// Rows one JSON array per line, after a line of column names and a line
/// of column types. It streams, so a read can stop at a limit, and the
/// types come with the result, so each cell is read by its own type.
pub(crate) const RESULT_FORMAT: &str = "JSONCompactEachRowWithNamesAndTypes";

/// How long a line of the body may grow before the read gives up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LineLimits {
    /// A header line holds the column names or types, which no real
    /// result makes this long. A longer one is a body in another format,
    /// which a FORMAT clause in user SQL asks for.
    pub(crate) header: usize,
    /// One row, which the read has to hold whole to decode.
    pub(crate) row: usize,
}

impl LineLimits {
    pub(crate) const DEFAULT: Self = Self {
        header: 16 << 20,
        row: 256 << 20,
    };
}

/// What a response body yields next.
#[derive(Debug)]
pub(crate) enum ReadEvent {
    Columns(Arc<[ResultColumn]>),
    Row(Vec<Value>),
    End,
}

/// A response body read as events. The state lives here rather than in
/// the future reading it, so it may be raced against a stop.
pub(crate) struct ResultReader<R = BytesCursor> {
    lines: LineReader<R>,
    limits: LineLimits,
    names: Option<Vec<String>>,
    plans: Option<Vec<CellPlan>>,
}

impl ResultReader {
    /// Send the query and read its body as events.
    pub(crate) fn open(query: Query) -> Result<Self, DriverError> {
        query
            .fetch_bytes(RESULT_FORMAT)
            .map(|cursor| Self::new(cursor, LineLimits::DEFAULT))
            .map_err(|error| map_error(&error))
    }

    pub(crate) fn written_rows(&self) -> Option<u64> {
        self.lines.written_rows()
    }
}

impl<R: AsyncBufRead + Unpin> ResultReader<R> {
    pub(crate) fn new(cursor: R, limits: LineLimits) -> Self {
        Self {
            lines: LineReader::new(cursor),
            limits,
            names: None,
            plans: None,
        }
    }

    /// Whether the body began with a result set. A statement without one,
    /// such as an INSERT or a CREATE, sends an empty body.
    pub(crate) fn has_result_set(&self) -> bool {
        self.plans.is_some()
    }

    pub(crate) async fn next_event(&mut self) -> Result<ReadEvent, DriverError> {
        loop {
            let limit = match self.plans {
                Some(_) => self.limits.row,
                None => self.limits.header,
            };
            let line = match self.lines.next_line(limit).await? {
                Line::Complete(line) => line,
                Line::TooLong if self.plans.is_some() => {
                    return Err(DriverError::Protocol(format!(
                        "a row ran past {} MiB, the most the driver reads into memory",
                        self.limits.row >> 20
                    )));
                }
                Line::TooLong => {
                    return Err(DriverError::Protocol(format!(
                        "the result did not come back as {RESULT_FORMAT}; a FORMAT clause in the query changes the format"
                    )));
                }
                Line::End => {
                    if self.names.is_some() && self.plans.is_none() {
                        return Err(DriverError::Protocol("the result ended inside its header".to_owned()));
                    }
                    return Ok(ReadEvent::End);
                }
            };
            if let Some(plans) = &self.plans {
                return decode_row(&line, plans).map(ReadEvent::Row);
            }
            let header = header_line(&line)?;
            let Some(names) = self.names.take() else {
                self.names = Some(header);
                continue;
            };
            if names.len() != header.len() {
                return Err(DriverError::Protocol(format!(
                    "the result named {} columns and typed {}",
                    names.len(),
                    header.len()
                )));
            }
            let (columns, plans): (Vec<ResultColumn>, Vec<CellPlan>) = names
                .into_iter()
                .zip(&header)
                .map(|(name, type_name)| {
                    let parsed = ClickHouseType::parse(type_name);
                    (ResultColumn::new(name, parsed.column_type), parsed.plan)
                })
                .unzip();
            self.plans = Some(plans);
            return Ok(ReadEvent::Columns(columns.into()));
        }
    }
}

fn header_line(line: &[u8]) -> Result<Vec<String>, DriverError> {
    serde_json::from_slice(line)
        .map_err(|error| DriverError::Protocol(format!("the result header could not be read: {error}")))
}

/// A whole result, for the driver's own catalogue reads and for reads
/// the grid pages through.
#[derive(Debug)]
pub(crate) struct ResultTable {
    pub(crate) columns: Arc<[ResultColumn]>,
    pub(crate) rows: Vec<Vec<Value>>,
    /// Rows past the limit were there and were not read.
    pub(crate) truncated: bool,
}

/// Read at most `limit` rows, and one more to learn whether the result
/// was cut short. Dropping the rest of the body closes its connection,
/// which with `cancel_http_readonly_queries_on_client_close` stops the
/// read on the server as well.
pub(crate) async fn read_table(query: Query, limit: Option<u64>) -> Result<ResultTable, DriverError> {
    let mut reader = ResultReader::open(query)?;
    let mut columns: Arc<[ResultColumn]> = Arc::from([]);
    let mut rows = Vec::new();
    loop {
        match reader.next_event().await? {
            ReadEvent::Columns(header) => columns = header,
            ReadEvent::Row(row) => {
                if limit.is_some_and(|limit| u64::try_from(rows.len()).unwrap_or(u64::MAX) >= limit) {
                    return Ok(ResultTable {
                        columns,
                        rows,
                        truncated: true,
                    });
                }
                rows.push(row);
            }
            ReadEvent::End => {
                return Ok(ResultTable {
                    columns,
                    rows,
                    truncated: false,
                });
            }
        }
    }
}

/// Run a statement whose rows nobody reads, to its end, and give back
/// the row count the server put in its summary.
pub(crate) async fn drain(query: Query) -> Result<Option<u64>, DriverError> {
    let mut reader = ResultReader::open(query)?;
    while !matches!(reader.next_event().await?, ReadEvent::End) {}
    Ok(reader.written_rows())
}

/// The cells of a catalogue row, read by position.
pub(crate) struct CatalogRow<'a>(pub(crate) &'a [Value]);

impl CatalogRow<'_> {
    pub(crate) fn text(&self, index: usize) -> Result<String, DriverError> {
        match self.0.get(index) {
            Some(Value::Text(text)) => Ok(text.clone()),
            Some(Value::Bytes(bytes)) => Ok(String::from_utf8_lossy(bytes).into_owned()),
            other => Err(unexpected(index, other)),
        }
    }

    pub(crate) fn texts(&self, index: usize) -> Result<Vec<String>, DriverError> {
        match self.0.get(index) {
            Some(Value::Array(values)) => values
                .iter()
                .map(|value| match value {
                    Value::Text(text) => Ok(text.clone()),
                    other => Err(unexpected(index, Some(other))),
                })
                .collect(),
            other => Err(unexpected(index, other)),
        }
    }

    pub(crate) fn optional_u64(&self, index: usize) -> Result<Option<u64>, DriverError> {
        match self.0.get(index) {
            Some(Value::Null) => Ok(None),
            Some(value) => value
                .as_exact_u64()
                .map(Some)
                .ok_or_else(|| unexpected(index, Some(value))),
            None => Err(unexpected(index, None)),
        }
    }

    pub(crate) fn integer(&self, index: usize) -> Result<i32, DriverError> {
        match self.0.get(index) {
            Some(Value::Int(value)) => i32::try_from(*value).map_err(|_| unexpected(index, self.0.get(index))),
            other => Err(unexpected(index, other)),
        }
    }

    pub(crate) fn flag(&self, index: usize) -> Result<bool, DriverError> {
        match self.0.get(index) {
            Some(Value::Bool(flag)) => Ok(*flag),
            Some(value) => Ok(value.as_exact_u64().ok_or_else(|| unexpected(index, Some(value)))? != 0),
            None => Err(unexpected(index, None)),
        }
    }
}

fn unexpected(index: usize, value: Option<&Value>) -> DriverError {
    DriverError::Protocol(format!("a catalogue column {index} held {value:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SMALL: LineLimits = LineLimits { header: 64, row: 16 };

    fn reader(body: &[u8]) -> ResultReader<&[u8]> {
        ResultReader::new(body, SMALL)
    }

    #[tokio::test]
    async fn a_body_reads_as_columns_rows_and_an_end() {
        let mut reader = reader(b"[\"n\"]\n[\"UInt8\"]\n[1]\n[2]\n");

        let ReadEvent::Columns(columns) = reader.next_event().await.expect("the header") else {
            panic!("the header was not read first");
        };
        assert_eq!(columns.len(), 1);
        for expected in [1, 2] {
            let ReadEvent::Row(row) = reader.next_event().await.expect("a row") else {
                panic!("row {expected} was not read");
            };
            assert_eq!(row, vec![Value::Int(expected)]);
        }
        assert!(matches!(reader.next_event().await, Ok(ReadEvent::End)));
    }

    #[tokio::test]
    async fn a_body_in_another_format_is_refused_at_the_header_limit() {
        let row_binary: Vec<u8> = b"\x01x".repeat(64);

        let refused = reader(&row_binary).next_event().await;

        let Err(DriverError::Protocol(message)) = refused else {
            panic!("a RowBinary body gave {refused:?}");
        };
        assert!(message.contains("FORMAT"), "{message}");
    }

    #[tokio::test]
    async fn a_row_past_the_row_limit_is_refused_after_the_rows_before_it() {
        let body = format!("[\"s\"]\n[\"String\"]\n[\"a\"]\n[\"{}\"]\n", "x".repeat(16));
        let mut reader = reader(body.as_bytes());

        assert!(matches!(reader.next_event().await, Ok(ReadEvent::Columns(_))));
        assert!(matches!(reader.next_event().await, Ok(ReadEvent::Row(_))));
        let refused = reader.next_event().await;
        assert!(
            matches!(&refused, Err(DriverError::Protocol(message)) if message.contains("MiB")),
            "{refused:?}"
        );
    }
}
