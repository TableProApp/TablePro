use tablepro_core::{DriverError, ReadEmitter, ReadStatement, ResultSink, StreamSummary};

use crate::call_client::CallClient;
use crate::result_reader::{ReadEvent, ResultReader};

/// Every row of a read, into the sink. The call's client carries
/// `readonly`, 1 for user SQL, so SQL that writes is refused by the
/// server for the read's whole length.
pub(crate) async fn stream(
    calls: &CallClient,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
) -> Result<StreamSummary, DriverError> {
    let query = match read {
        ReadStatement::Generated(statement) => calls.statement(statement)?,
        ReadStatement::User(sql) => calls.raw(sql.as_str())?,
    };
    let mut reader = ResultReader::open(query)?;
    // A consumer that went away ends the read, and dropping the body stops it on the server.
    let mut emitter = ReadEmitter::new(sink);
    loop {
        match reader.next_event().await? {
            ReadEvent::Columns(columns) => emitter.start(columns).await?,
            ReadEvent::Row(row) => emitter.row(row).await?,
            ReadEvent::End => break,
        }
    }
    if reader.has_result_set() {
        emitter.finish().await?;
    }
    Ok(StreamSummary::new(emitter.rows()))
}
