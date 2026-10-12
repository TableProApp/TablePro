use std::sync::Arc;

use clickhouse::query::{BytesCursor, Query};
use tablepro_core::column::ResultColumn;
use tablepro_core::{DriverError, Value};

use crate::cell_seed::CellPlan;
use crate::clickhouse_type::ClickHouseType;
use crate::errors::map_error;
use crate::line_reader::LineReader;
use crate::row_seed::decode_row;

/// Rows one JSON array per line, after a line of column names and a line
/// of column types. It streams, so a read can stop at a limit, and the
/// types come with the result, so each cell is read by its own type.
pub(crate) const RESULT_FORMAT: &str = "JSONCompactEachRowWithNamesAndTypes";

/// What a response body yields next.
#[derive(Debug)]
pub(crate) enum ReadEvent {
    Columns(Arc<[ResultColumn]>),
    Row(Vec<Value>),
    End,
}

/// A response body read as events. The state lives here rather than in
/// the future reading it, so it may be raced against a stop.
pub(crate) struct ResultReader {
    lines: LineReader,
    names: Option<Vec<String>>,
    plans: Option<Vec<CellPlan>>,
}

impl ResultReader {
    pub(crate) fn new(cursor: BytesCursor) -> Self {
        Self {
            lines: LineReader::new(cursor),
            names: None,
            plans: None,
        }
    }

    /// Send the query and read its body as events.
    pub(crate) fn open(query: Query) -> Result<Self, DriverError> {
        query
            .fetch_bytes(RESULT_FORMAT)
            .map(Self::new)
            .map_err(|error| map_error(&error))
    }

    /// Whether the body began with a result set. A statement without one,
    /// such as an INSERT or a CREATE, sends an empty body.
    pub(crate) fn has_result_set(&self) -> bool {
        self.plans.is_some()
    }

    pub(crate) fn written_rows(&self) -> Option<u64> {
        self.lines.written_rows()
    }

    pub(crate) async fn next_event(&mut self) -> Result<ReadEvent, DriverError> {
        loop {
            let Some(line) = self.lines.next_line().await? else {
                if self.names.is_some() && self.plans.is_none() {
                    return Err(DriverError::Protocol("the result ended inside its header".to_owned()));
                }
                return Ok(ReadEvent::End);
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
