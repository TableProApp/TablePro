use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::{ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation, Value};
use tiberius::QueryItem;

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::encode::{as_sql, encode_params};
use crate::in_band_request::{Interrupt, Watch};
use crate::physical::MssqlClient;
use crate::read_only_guard::{guarded_error, refuse_writes, wrap};

const BATCH_ROWS: usize = 256;

/// Every row of a read, into the sink. User SQL must be a plain read,
/// and the whole read runs inside a transaction that is rolled back, so
/// a write that slips past the check still does not land.
pub(crate) async fn stream(
    client: &mut MssqlClient,
    watch: &Watch,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
) -> Result<StreamSummary, Interrupt> {
    let (sql, params) = match read {
        ReadStatement::Generated(statement) => (statement.sql(), encode_params(statement.params())?),
        ReadStatement::User(sql) => {
            refuse_writes(sql.as_str())?;
            (sql.as_str(), Vec::new())
        }
    };
    let guarded = wrap(sql);
    let refs = as_sql(&params);
    let mut emitter = Emitter {
        sink,
        batch: Vec::new(),
        open: false,
        set_rows: 0,
        rows: 0,
    };
    let mut stream = watch
        .start(client.query(guarded.as_str(), &refs))
        .await
        .map_err(guard)?;
    while let Some(item) = watch.next(&mut stream).await.map_err(guard)? {
        let flow = match item {
            QueryItem::Metadata(metadata) => {
                let columns: Arc<[ResultColumn]> = metadata.columns().iter().map(result_column).collect();
                emitter.start(columns).await
            }
            QueryItem::Row(row) => emitter.row(decode_row(&row)).await,
        };
        if flow == SinkFlow::ConsumerGone {
            // The connection is closed after this call, which ends the
            // response on the server too.
            watch.spoil();
            return Ok(StreamSummary::new(emitter.rows));
        }
    }
    if emitter.finish().await == SinkFlow::ConsumerGone {
        watch.spoil();
    }
    Ok(StreamSummary::new(emitter.rows))
}

fn guard(interrupt: Interrupt) -> Interrupt {
    match interrupt {
        Interrupt::Failed(error) => Interrupt::Failed(guarded_error(error)),
        other => other,
    }
}

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    batch: Vec<Vec<Value>>,
    open: bool,
    set_rows: u64,
    rows: u64,
}

impl Emitter<'_> {
    async fn start(&mut self, columns: Arc<[ResultColumn]>) -> SinkFlow {
        if self.finish().await == SinkFlow::ConsumerGone {
            return SinkFlow::ConsumerGone;
        }
        self.open = true;
        self.sink.accept(ResultEvent::ResultSetStarted { columns }).await
    }

    async fn row(&mut self, values: Vec<Value>) -> SinkFlow {
        self.batch.push(values);
        self.set_rows += 1;
        self.rows += 1;
        if self.batch.len() < BATCH_ROWS {
            return SinkFlow::Continue;
        }
        self.sink
            .accept(ResultEvent::Rows(std::mem::take(&mut self.batch)))
            .await
    }

    /// Close the result set that is open, if one is.
    async fn finish(&mut self) -> SinkFlow {
        if !self.open {
            return SinkFlow::Continue;
        }
        if !self.batch.is_empty()
            && self
                .sink
                .accept(ResultEvent::Rows(std::mem::take(&mut self.batch)))
                .await
                == SinkFlow::ConsumerGone
        {
            return SinkFlow::ConsumerGone;
        }
        self.open = false;
        let retained = std::mem::take(&mut self.set_rows);
        self.sink
            .accept(ResultEvent::ResultSetFinished {
                retained,
                total_rows: Some(retained),
                truncation: Truncation::Complete,
            })
            .await
    }
}
