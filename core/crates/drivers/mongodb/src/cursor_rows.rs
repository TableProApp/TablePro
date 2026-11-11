use bson::Document;
use mongodb::{ClientSession, SessionCursor};
use tablepro_core::{DriverError, LossPhase, ResultEvent, ResultSink, RowLimit, SinkFlow, StopRequest, Truncation};

use crate::endpoint::MongoEndpoint;
use crate::rows::{BATCH_ROWS, Layout};
use crate::shell_command::Columns;

/// Stream a cursor into `sink` as the result set `set_index`. With a
/// `limit`, as an editor reads, at most that many documents are kept; with
/// none, as an export reads, every one, under columns fixed before the
/// first row.
pub(crate) async fn stream(
    read: Read<'_>,
    columns: Columns,
    sink: &mut dyn ResultSink,
    limit: Option<RowLimit>,
    set_index: usize,
) -> Result<(SinkFlow, u64), DriverError> {
    let discovered = matches!(columns, Columns::Discovered);
    match (limit, discovered) {
        (Some(limit), true) => discovered_kept(read, columns, sink, limit).await,
        (Some(limit), false) => named_kept(read, columns, sink, limit, set_index).await,
        (None, _) => every(read, columns, sink).await,
    }
}

/// A cursor, the session it reads in, and the stop of the call that
/// reads it.
pub(crate) struct Read<'a> {
    endpoint: &'a MongoEndpoint,
    cursor: SessionCursor<Document>,
    session: &'a mut ClientSession,
    stop: &'a StopRequest,
}

impl<'a> Read<'a> {
    pub(crate) fn new(
        endpoint: &'a MongoEndpoint,
        cursor: SessionCursor<Document>,
        session: &'a mut ClientSession,
        stop: &'a StopRequest,
    ) -> Self {
        Self {
            endpoint,
            cursor,
            session,
            stop,
        }
    }

    /// The next document, `None` once the cursor is spent. A stop ends the
    /// read before it asks for more, and dropping the cursor closes it on
    /// the server: a cursor waiting between batches runs no operation, so
    /// a `killOp` finds nothing to end.
    pub(crate) async fn next(&mut self) -> Result<Option<Document>, DriverError> {
        if self.stop.is_requested() {
            return Err(crate::call::stopped(self.stop));
        }
        match self.cursor.advance(self.session).await {
            Ok(true) => crate::nested_document::current_document(&self.cursor).map(Some),
            Ok(false) => Ok(None),
            Err(error) => Err(self.endpoint.explain(&error, LossPhase::Statement).await),
        }
    }

    /// Up to a batch of the `room` documents left to keep, and how the set
    /// ends when it does: a full `room` reads one more to say whether the
    /// result was cut.
    async fn batch(&mut self, room: u64) -> Result<(Vec<Document>, Option<Truncation>), DriverError> {
        let take = usize::try_from(room).unwrap_or(usize::MAX).min(BATCH_ROWS);
        let mut documents = Vec::with_capacity(take);
        while documents.len() < take {
            match self.next().await? {
                Some(document) => documents.push(document),
                None => return Ok((documents, Some(Truncation::Complete))),
            }
        }
        if (documents.len() as u64) < room {
            return Ok((documents, None));
        }
        let end = match self.next().await? {
            Some(_) => Truncation::ReadPastLimit,
            None => Truncation::Complete,
        };
        Ok((documents, Some(end)))
    }
}

/// At most `limit` documents under columns found from them. A later
/// document can add a column, so the documents kept are all read before
/// the first row is shown. One more says whether the result was cut, and
/// dropping the cursor closes it on the server, so the rest is never read.
async fn discovered_kept(
    mut read: Read<'_>,
    columns: Columns,
    sink: &mut dyn ResultSink,
    limit: RowLimit,
) -> Result<(SinkFlow, u64), DriverError> {
    let mut documents = Vec::new();
    let mut more = false;
    while let Some(document) = read.next().await? {
        if documents.len() as u64 == limit.get() {
            more = true;
            break;
        }
        documents.push(document);
    }
    drop(read);
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
    let end = match more {
        true => Truncation::ReadPastLimit,
        false => Truncation::Complete,
    };
    Ok((close(sink, retained, end).await, retained))
}

/// At most `limit` documents under columns a projection names, a batch at
/// a time, each accepted before the next is read. The set starts with the
/// types its first batch holds, and ends with `ColumnsResolved` when the
/// rows after it hold others. One more document says whether the result
/// was cut, and dropping the cursor closes it on the server, so the rest is
/// never read.
async fn named_kept(
    mut read: Read<'_>,
    columns: Columns,
    sink: &mut dyn ResultSink,
    limit: RowLimit,
    set_index: usize,
) -> Result<(SinkFlow, u64), DriverError> {
    let mut layout = Layout::new(&columns);
    let (mut documents, mut ending) = read.batch(limit.get()).await?;
    for document in &documents {
        layout.learn(document);
    }
    let announced = layout.columns();
    let started = ResultEvent::ResultSetStarted {
        columns: announced.clone(),
    };
    if sink.accept(started).await == SinkFlow::ConsumerGone {
        return Ok((SinkFlow::ConsumerGone, 0));
    }
    let mut retained: u64 = 0;
    let end = loop {
        if !documents.is_empty() {
            retained += documents.len() as u64;
            let rows = documents.iter().map(|document| layout.row(document)).collect();
            if sink.accept(ResultEvent::Rows(rows)).await == SinkFlow::ConsumerGone {
                return Ok((SinkFlow::ConsumerGone, retained));
            }
        }
        if let Some(end) = ending {
            break end;
        }
        (documents, ending) = read.batch(limit.get() - retained).await?;
        for document in &documents {
            layout.learn(document);
        }
    };
    drop(read);
    let columns = layout.columns();
    if columns != announced {
        let resolved = ResultEvent::ColumnsResolved { set_index, columns };
        if sink.accept(resolved).await == SinkFlow::ConsumerGone {
            return Ok((SinkFlow::ConsumerGone, retained));
        }
    }
    Ok((close(sink, retained, end).await, retained))
}

/// End a kept set: `RowLimitReached` first when the result was cut.
async fn close(sink: &mut dyn ResultSink, retained: u64, end: Truncation) -> SinkFlow {
    match end {
        Truncation::Complete => finish(sink, retained, Some(retained), Truncation::Complete).await,
        cut => {
            if sink.accept(ResultEvent::RowLimitReached { retained }).await == SinkFlow::ConsumerGone {
                return SinkFlow::ConsumerGone;
            }
            finish(sink, retained, None, cut).await
        }
    }
}

/// Every document, a batch at a time. The columns are set before the
/// first row is written, so a document with a field outside them, which
/// a write between the export's two reads can bring, fails the read
/// rather than losing the field.
async fn every(
    mut read: Read<'_>,
    columns: Columns,
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
            match read.next().await? {
                Some(document) => documents.push(document),
                None => {
                    exhausted = true;
                    break;
                }
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

async fn finish(sink: &mut dyn ResultSink, retained: u64, total_rows: Option<u64>, truncation: Truncation) -> SinkFlow {
    sink.accept(ResultEvent::ResultSetFinished {
        retained,
        total_rows,
        truncation,
    })
    .await
}
