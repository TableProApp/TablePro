use bson::Document;
use mongodb::{ClientSession, SessionCursor};
use tablepro_core::{DriverError, LossPhase, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation};

use crate::endpoint::MongoEndpoint;
use crate::rows::{BATCH_ROWS, Layout};
use crate::shell_command::Columns;

/// Stream a cursor into `sink`. With a `limit`, as an editor reads, the
/// documents kept are all read before the first row is shown, so the
/// columns hold every field they have. With none, as an export reads,
/// each batch is accepted before the next is read, under columns fixed
/// before the first row.
pub(crate) async fn stream(
    endpoint: &MongoEndpoint,
    cursor: SessionCursor<Document>,
    columns: Columns,
    session: &mut ClientSession,
    sink: &mut dyn ResultSink,
    limit: Option<RowLimit>,
) -> Result<(SinkFlow, u64), DriverError> {
    match limit {
        Some(limit) => kept(endpoint, cursor, columns, session, sink, limit).await,
        None => every(endpoint, cursor, columns, session, sink).await,
    }
}

/// At most `limit` documents. One more says whether the result was cut,
/// and dropping the cursor closes it on the server, so the rest is never
/// read.
async fn kept(
    endpoint: &MongoEndpoint,
    mut cursor: SessionCursor<Document>,
    columns: Columns,
    session: &mut ClientSession,
    sink: &mut dyn ResultSink,
    limit: RowLimit,
) -> Result<(SinkFlow, u64), DriverError> {
    let mut documents = Vec::new();
    let mut more = false;
    loop {
        match cursor.advance(session).await {
            Ok(true) if (documents.len() as u64) < limit.get() => documents.push(current(&cursor)?),
            Ok(true) => {
                more = true;
                break;
            }
            Ok(false) => break,
            Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
        }
    }
    drop(cursor);
    let mut layout = Layout::new(&columns);
    for document in &documents {
        layout.learn(document);
    }
    let started = ResultEvent::ResultSetStarted {
        columns: layout.columns(),
    };
    if sink.accept(started).await == SinkFlow::ConsumerGone {
        return Ok((SinkFlow::ConsumerGone, 0));
    }
    let retained = documents.len() as u64;
    for batch in documents.chunks(BATCH_ROWS) {
        let rows = batch.iter().map(|document| layout.row(document)).collect();
        if sink.accept(ResultEvent::Rows(rows)).await == SinkFlow::ConsumerGone {
            return Ok((SinkFlow::ConsumerGone, retained));
        }
    }
    if !more {
        return Ok((
            finish(sink, retained, Some(retained), Truncation::Complete).await,
            retained,
        ));
    }
    if sink.accept(ResultEvent::RowLimitReached { retained }).await == SinkFlow::ConsumerGone {
        return Ok((SinkFlow::ConsumerGone, retained));
    }
    Ok((finish(sink, retained, None, Truncation::ReadPastLimit).await, retained))
}

/// Every document, a batch at a time. The columns are set before the
/// first row is written, so a document with a field outside them, which
/// a write between the export's two reads can bring, fails the read
/// rather than losing the field.
async fn every(
    endpoint: &MongoEndpoint,
    mut cursor: SessionCursor<Document>,
    columns: Columns,
    session: &mut ClientSession,
    sink: &mut dyn ResultSink,
) -> Result<(SinkFlow, u64), DriverError> {
    let found = matches!(columns, Columns::Discovered);
    let mut layout = Layout::new(&columns);
    let mut retained: u64 = 0;
    let mut started = false;
    loop {
        let mut documents = Vec::new();
        let mut exhausted = false;
        while documents.len() < BATCH_ROWS {
            match cursor.advance(session).await {
                Ok(true) => documents.push(current(&cursor)?),
                Ok(false) => {
                    exhausted = true;
                    break;
                }
                Err(error) => return Err(endpoint.explain(&error, LossPhase::Statement).await),
            }
        }
        for document in &documents {
            if layout.learn(document) && (started || !found) {
                return Err(DriverError::Protocol(
                    "a document gained a field while the export read it; export again".to_owned(),
                ));
            }
        }
        if !started {
            started = true;
            let event = ResultEvent::ResultSetStarted {
                columns: layout.columns(),
            };
            if sink.accept(event).await == SinkFlow::ConsumerGone {
                return Ok((SinkFlow::ConsumerGone, retained));
            }
        }
        if !documents.is_empty() {
            retained += documents.len() as u64;
            let rows = documents.iter().map(|document| layout.row(document)).collect();
            if sink.accept(ResultEvent::Rows(rows)).await == SinkFlow::ConsumerGone {
                return Ok((SinkFlow::ConsumerGone, retained));
            }
        }
        if exhausted {
            return Ok((
                finish(sink, retained, Some(retained), Truncation::Complete).await,
                retained,
            ));
        }
    }
}

fn current(cursor: &SessionCursor<Document>) -> Result<Document, DriverError> {
    cursor.deserialize_current().map_err(|error| DriverError::Decode {
        column: String::new(),
        detail: error.to_string(),
    })
}

async fn finish(sink: &mut dyn ResultSink, retained: u64, total_rows: Option<u64>, truncation: Truncation) -> SinkFlow {
    sink.accept(ResultEvent::ResultSetFinished {
        retained,
        total_rows,
        truncation,
    })
    .await
}
