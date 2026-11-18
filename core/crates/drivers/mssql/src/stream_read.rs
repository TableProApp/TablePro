use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::{DriverError, ReadEmitter, ReadStatement, ResultSink, StreamSummary};
use tiberius::QueryItem;

use crate::catalog::result_column;
use crate::decode::decode_row;
use crate::encode::{as_sql, encode_params};
use crate::in_band_request::{Interrupt, Watch};
use crate::physical::MssqlClient;
use crate::read_only_guard::{guarded_error, refuse_writes, wrap};

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
    let mut emitter = ReadEmitter::new(sink);
    let mut stream = watch
        .start(client.query(guarded.as_str(), &refs))
        .await
        .map_err(guard)?;
    while let Some(item) = watch.next(&mut stream).await.map_err(guard)? {
        let emitted = match item {
            QueryItem::Metadata(metadata) => {
                let columns: Arc<[ResultColumn]> = metadata.columns().iter().map(result_column).collect();
                next_set(&mut emitter, columns).await
            }
            QueryItem::Row(row) => emitter.row(decode_row(&row)).await,
        };
        // The emitter fails only when the consumer went away. The
        // connection is closed after this call, which ends the response
        // on the server too.
        if emitted.is_err() {
            watch.spoil();
            return Ok(StreamSummary::new(emitter.rows()));
        }
    }
    if emitter.is_open() && emitter.finish().await.is_err() {
        watch.spoil();
    }
    Ok(StreamSummary::new(emitter.rows()))
}

async fn next_set(emitter: &mut ReadEmitter<'_>, columns: Arc<[ResultColumn]>) -> Result<(), DriverError> {
    if emitter.is_open() {
        emitter.finish().await?;
    }
    emitter.start(columns).await
}

fn guard(interrupt: Interrupt) -> Interrupt {
    match interrupt {
        Interrupt::Failed(error) => Interrupt::Failed(guarded_error(error)),
        other => other,
    }
}
