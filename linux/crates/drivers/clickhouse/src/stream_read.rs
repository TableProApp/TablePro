use tablepro_core::{DriverError, ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation, Value};

use crate::call_client::CallClient;
use crate::result_reader::{ReadEvent, ResultReader};

const BATCH_ROWS: usize = 256;

/// Every row of a read, into the sink. The call's client carries
/// `readonly=2`, so user SQL that writes is refused by the server for
/// the read's whole length.
pub(crate) async fn stream(
    calls: &CallClient,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
) -> Result<StreamSummary, DriverError> {
    let query = match read {
        ReadStatement::Generated(statement) => calls.statement(statement),
        ReadStatement::User(sql) => calls.raw(sql.as_str()),
    };
    let mut reader = ResultReader::open(query)?;
    let mut emitter = Emitter {
        sink,
        batch: Vec::new(),
        rows: 0,
    };
    loop {
        match reader.next_event().await? {
            ReadEvent::Columns(columns) => emitter.send(ResultEvent::ResultSetStarted { columns }).await?,
            ReadEvent::Row(row) => emitter.row(row).await?,
            ReadEvent::End => break,
        }
    }
    if reader.has_result_set() {
        emitter.flush().await?;
        let rows = emitter.rows;
        emitter
            .send(ResultEvent::ResultSetFinished {
                retained: rows,
                total_rows: Some(rows),
                truncation: Truncation::Complete,
            })
            .await?;
    }
    Ok(StreamSummary::new(emitter.rows))
}

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    batch: Vec<Vec<Value>>,
    rows: u64,
}

impl Emitter<'_> {
    async fn row(&mut self, values: Vec<Value>) -> Result<(), DriverError> {
        self.batch.push(values);
        self.rows += 1;
        if self.batch.len() >= BATCH_ROWS {
            self.flush().await?;
        }
        Ok(())
    }

    async fn flush(&mut self) -> Result<(), DriverError> {
        if self.batch.is_empty() {
            return Ok(());
        }
        let rows = std::mem::take(&mut self.batch);
        self.send(ResultEvent::Rows(rows)).await
    }

    /// A consumer that went away ends the read: the rows would go
    /// nowhere, and dropping the body stops the read on the server.
    async fn send(&mut self, event: ResultEvent) -> Result<(), DriverError> {
        match self.sink.accept(event).await {
            SinkFlow::Continue => Ok(()),
            SinkFlow::ConsumerGone => Err(DriverError::Cancelled),
        }
    }
}
