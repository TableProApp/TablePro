use std::sync::Arc;

use redis::Value as Reply;
use tablepro_core::{DriverError, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation};
use tablepro_core::column::{
    ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, ResultColumn, TextLength,
};
use tablepro_core::value::{JsonText, Value};

use crate::errors::server_error;
use crate::key_name::quoted_argument;

/// What one reply shows as: a bare `OK`, or a table of rows.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ReplyShape {
    Done,
    Table {
        columns: Arc<[ResultColumn]>,
        rows: Vec<Vec<Value>>,
    },
}

/// A reply as redis-cli lays it out: one value in a cell of its own, an
/// array numbered from 1, a map by its keys. An element that is itself
/// an array or a map is a JSON cell, so no reply loses its nesting. An
/// error reply is the command failing.
pub(crate) fn reply_shape(reply: Reply) -> Result<ReplyShape, DriverError> {
    let single = |cell: Value| ReplyShape::Table {
        columns: Arc::from([text_column("value")]),
        rows: vec![vec![cell]],
    };
    Ok(match reply {
        Reply::Okay => ReplyShape::Done,
        Reply::ServerError(error) => return Err(server_error(&error)),
        Reply::Attribute { data, .. } => return reply_shape(*data),
        Reply::Array(items) | Reply::Set(items) | Reply::Push { data: items, .. } => ReplyShape::Table {
            columns: Arc::from([integer_column("#"), text_column("value")]),
            rows: items
                .into_iter()
                .enumerate()
                .map(|(index, item)| vec![Value::Int(position(index)), cell(item)])
                .collect(),
        },
        Reply::Map(pairs) => ReplyShape::Table {
            columns: Arc::from([text_column("key"), text_column("value")]),
            rows: pairs.into_iter().map(|(key, value)| vec![cell(key), cell(value)]).collect(),
        },
        other => single(cell(other)),
    })
}

/// One element of a reply as a grid cell.
pub(crate) fn cell(reply: Reply) -> Value {
    match reply {
        Reply::Nil => Value::Null,
        Reply::Int(number) => Value::Int(number),
        Reply::BulkString(bytes) => bytes_cell(bytes),
        Reply::SimpleString(text) => Value::Text(text),
        Reply::Okay => Value::Text("OK".to_owned()),
        Reply::Double(number) => Value::Float64(number),
        Reply::Boolean(flag) => Value::Bool(flag),
        Reply::VerbatimString { text, .. } => Value::Text(text),
        Reply::BigNumber(digits) => Value::Text(String::from_utf8_lossy(&digits).into_owned()),
        Reply::ServerError(error) => Value::Text(error.to_string()),
        Reply::Attribute { data, .. } => cell(*data),
        nested => match JsonText::parse(json(&nested).to_string()) {
            Ok(text) => Value::Json(text),
            Err(_) => Value::Null,
        },
    }
}

/// A binary-safe string: text when it is UTF-8, bytes otherwise.
pub(crate) fn bytes_cell(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(text) => Value::Text(text),
        Err(error) => Value::Bytes(error.into_bytes()),
    }
}

fn json(reply: &Reply) -> serde_json::Value {
    use serde_json::Value as Json;
    match reply {
        Reply::Nil => Json::Null,
        Reply::Int(number) => Json::from(*number),
        Reply::Double(number) => serde_json::Number::from_f64(*number).map_or(Json::Null, Json::Number),
        Reply::Boolean(flag) => Json::Bool(*flag),
        Reply::BulkString(bytes) => Json::String(match std::str::from_utf8(bytes) {
            Ok(text) => text.to_owned(),
            Err(_) => quoted_argument(bytes),
        }),
        Reply::SimpleString(text) | Reply::VerbatimString { text, .. } => Json::String(text.clone()),
        Reply::Okay => Json::String("OK".to_owned()),
        Reply::BigNumber(digits) => Json::String(String::from_utf8_lossy(digits).into_owned()),
        Reply::ServerError(error) => Json::String(error.to_string()),
        Reply::Array(items) | Reply::Set(items) | Reply::Push { data: items, .. } => {
            Json::Array(items.iter().map(json).collect())
        }
        // A key need not be a string, so a map keeps its pairs.
        Reply::Map(pairs) => Json::Array(
            pairs
                .iter()
                .map(|(key, value)| Json::Array(vec![json(key), json(value)]))
                .collect(),
        ),
        Reply::Attribute { data, .. } => json(data),
        _ => Json::Null,
    }
}

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a
/// slow grid slows the run instead of growing a queue.
const BATCH_ROWS: usize = 256;

/// Stream one reply into `sink`, keeping at most `limit` rows of a table.
/// The reply is already whole in memory, so the rows past the limit are
/// counted and dropped.
pub(crate) async fn emit(sink: &mut dyn ResultSink, shape: ReplyShape, limit: Option<RowLimit>) -> SinkFlow {
    let (columns, mut rows) = match shape {
        ReplyShape::Done => return sink.accept(ResultEvent::CommandCompleted { rows_affected: None }).await,
        ReplyShape::Table { columns, rows } => (columns, rows),
    };
    let total = rows.len() as u64;
    let retained = limit.map_or(total, |limit| limit.get().min(total));
    rows.truncate(usize::try_from(retained).unwrap_or(usize::MAX));
    if sink.accept(ResultEvent::ResultSetStarted { columns }).await == SinkFlow::ConsumerGone {
        return SinkFlow::ConsumerGone;
    }
    let mut rows = rows.into_iter().peekable();
    while rows.peek().is_some() {
        let batch: Vec<_> = rows.by_ref().take(BATCH_ROWS).collect();
        if sink.accept(ResultEvent::Rows(batch)).await == SinkFlow::ConsumerGone {
            return SinkFlow::ConsumerGone;
        }
    }
    let cut = retained < total;
    if cut && sink.accept(ResultEvent::RowLimitReached { retained }).await == SinkFlow::ConsumerGone {
        return SinkFlow::ConsumerGone;
    }
    sink.accept(ResultEvent::ResultSetFinished {
        retained,
        total_rows: Some(total),
        truncation: if cut {
            Truncation::ReadPastLimit
        } else {
            Truncation::Complete
        },
    })
    .await
}

fn position(index: usize) -> i64 {
    i64::try_from(index).map_or(i64::MAX, |index| index.saturating_add(1))
}

pub(crate) fn text_column(name: &str) -> ResultColumn {
    ResultColumn::new(
        name,
        ColumnType {
            name: "string".to_owned(),
            kind: ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            catalog: None,
            dynamic_storage: true,
            read_form: ReadForm::Native,
        },
    )
}

pub(crate) fn integer_column(name: &str) -> ResultColumn {
    ResultColumn::new(
        name,
        ColumnType {
            name: "integer".to_owned(),
            kind: ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: true,
            }),
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        },
    )
}

pub(crate) fn float_column(name: &str) -> ResultColumn {
    ResultColumn::new(
        name,
        ColumnType {
            name: "double".to_owned(),
            kind: ColumnKind::Float(FloatWidth::F64),
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(shape: ReplyShape) -> (Vec<String>, Vec<Vec<Value>>) {
        match shape {
            ReplyShape::Table { columns, rows } => (columns.iter().map(|column| column.name.clone()).collect(), rows),
            ReplyShape::Done => (Vec::new(), Vec::new()),
        }
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn ok_is_a_command_that_completed() {
        assert_eq!(reply_shape(Reply::Okay), Ok(ReplyShape::Done));
    }

    #[test]
    fn a_single_value_is_one_cell() {
        assert_eq!(
            table(reply_shape(Reply::Int(42)).unwrap()),
            (vec!["value".to_owned()], vec![vec![Value::Int(42)]])
        );
        assert_eq!(table(reply_shape(Reply::Nil).unwrap()).1, vec![vec![Value::Null]]);
        assert_eq!(
            table(reply_shape(Reply::BulkString(b"\xff\x00".to_vec())).unwrap()).1,
            vec![vec![Value::Bytes(b"\xff\x00".to_vec())]]
        );
    }

    #[test]
    fn an_array_is_numbered_from_one() {
        let reply = Reply::Array(vec![Reply::BulkString(b"a".to_vec()), Reply::Nil]);

        assert_eq!(
            table(reply_shape(reply).unwrap()),
            (
                vec!["#".to_owned(), "value".to_owned()],
                vec![vec![Value::Int(1), text("a")], vec![Value::Int(2), Value::Null]]
            )
        );
    }

    #[test]
    fn a_nested_array_is_a_json_cell() {
        let reply = Reply::Array(vec![
            Reply::BulkString(b"0".to_vec()),
            Reply::Array(vec![Reply::BulkString(b"k1".to_vec()), Reply::BulkString(b"\xff".to_vec())]),
        ]);

        let (_, rows) = table(reply_shape(reply).unwrap());

        assert_eq!(
            rows[1][1],
            Value::Json(JsonText::parse(r#"["k1","\"\\xff\""]"#.to_owned()).unwrap())
        );
    }

    struct Recorder(Vec<ResultEvent>);

    #[async_trait::async_trait]
    impl ResultSink for Recorder {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.0.push(event);
            SinkFlow::Continue
        }
    }

    #[tokio::test]
    async fn rows_past_the_limit_are_counted_and_dropped() {
        let items = (0..5).map(Reply::Int).collect();
        let mut sink = Recorder(Vec::new());

        let flow = emit(&mut sink, reply_shape(Reply::Array(items)).unwrap(), RowLimit::new(3)).await;

        assert_eq!(flow, SinkFlow::Continue);
        let rows: usize = sink
            .0
            .iter()
            .map(|event| match event {
                ResultEvent::Rows(rows) => rows.len(),
                _ => 0,
            })
            .sum();
        assert_eq!(rows, 3);
        assert!(sink.0.contains(&ResultEvent::RowLimitReached { retained: 3 }));
        assert_eq!(
            sink.0.last(),
            Some(&ResultEvent::ResultSetFinished {
                retained: 3,
                total_rows: Some(5),
                truncation: Truncation::ReadPastLimit
            })
        );
    }

    #[tokio::test]
    async fn ok_completes_a_command() {
        let mut sink = Recorder(Vec::new());

        emit(&mut sink, ReplyShape::Done, None).await;

        assert_eq!(sink.0, [ResultEvent::CommandCompleted { rows_affected: None }]);
    }

    #[test]
    fn an_error_reply_fails_the_command() {
        let reply = redis::parse_redis_value(b"-WRONGTYPE Operation against a key\r\n").unwrap();

        let Err(DriverError::Server(diagnostics)) = reply_shape(reply) else {
            panic!("an error reply did not fail");
        };
        assert_eq!(diagnostics.message, "Operation against a key");
    }
}
