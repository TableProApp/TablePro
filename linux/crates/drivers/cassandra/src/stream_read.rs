//! Every row of a read into a sink, page by page, for an export.

use scylla::response::PagingState;
use scylla::statement::unprepared::Statement as CqlStatement;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{
    DriverError, LossPhase, ReadOnlyRefusal, ReadStatement, ResultEvent, ResultSink, SinkFlow, StopRequest,
    StreamSummary, Truncation, Value,
};

use crate::call::stoppable;
use crate::errors::execution_error;
use crate::rows::{ColumnsRead, MAX_PAGE_ROWS, next_state, page_size};
use crate::session::CqlLink;

const BATCH_ROWS: usize = 256;

/// CQL has no read-only session, so user SQL that is not a plain read is
/// refused before it is sent; generated reads are SELECTs. Each page is
/// asked for once the sink took the last.
pub(crate) async fn stream(
    link: &CqlLink,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
    stop: &StopRequest,
) -> Result<StreamSummary, DriverError> {
    let mut emitter = Emitter { sink, rows: 0 };
    match read {
        ReadStatement::Generated(statement) => {
            let mut paging = PagingState::start();
            let mut columns: Option<ColumnsRead> = None;
            let mut rows = 0;
            loop {
                let page = link.page(statement, page_size(MAX_PAGE_ROWS), paging);
                let (result, response) = stoppable(stop, page).await?;
                let page_rows = result
                    .into_rows_result()
                    .map_err(|error| DriverError::Protocol(error.to_string()))?;
                if columns.is_none() {
                    let read = ColumnsRead::of(page_rows.column_specs());
                    emitter
                        .send(ResultEvent::ResultSetStarted {
                            columns: read.columns.clone(),
                        })
                        .await?;
                    columns = Some(read);
                }
                let decoded = columns
                    .as_ref()
                    .map_or(Ok(Vec::new()), |read| read.decode(&page_rows))?;
                rows += emitter.rows(decoded).await?;
                match next_state(response) {
                    Some(next) => paging = next,
                    None => break,
                }
            }
            emitter.finished(rows).await?;
        }
        ReadStatement::User(sql) => {
            if statement_access(sql.as_str(), SqlGrammar::Cql) != StatementAccess::Read {
                return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
            }
            let plan = ScriptPlan::build(
                sql.as_str(),
                SqlGrammar::Cql,
                LexicalSettings::default_for(SqlGrammar::Cql),
            );
            for statement in plan.statements() {
                user_statement(link, statement.text(sql.as_str()), &mut emitter, stop).await?;
            }
        }
    }
    Ok(StreamSummary::new(emitter.rows))
}

async fn user_statement(
    link: &CqlLink,
    text: &str,
    emitter: &mut Emitter<'_>,
    stop: &StopRequest,
) -> Result<(), DriverError> {
    let mut statement = CqlStatement::new(text);
    statement.set_page_size(page_size(MAX_PAGE_ROWS));
    let mut paging = PagingState::start();
    let mut columns: Option<ColumnsRead> = None;
    let mut rows = 0;
    loop {
        let page = link.session().query_single_page(statement.clone(), (), paging);
        let (result, response) = stoppable(stop, async {
            page.await.map_err(|error| execution_error(error, LossPhase::Statement))
        })
        .await?;
        if !result.is_rows() {
            return Ok(());
        }
        let page_rows = result
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        if columns.is_none() {
            let read = ColumnsRead::of(page_rows.column_specs());
            emitter
                .send(ResultEvent::ResultSetStarted {
                    columns: read.columns.clone(),
                })
                .await?;
            columns = Some(read);
        }
        let decoded = columns
            .as_ref()
            .map_or(Ok(Vec::new()), |read| read.decode(&page_rows))?;
        rows += emitter.rows(decoded).await?;
        match next_state(response) {
            Some(next) => paging = next,
            None => return emitter.finished(rows).await,
        }
    }
}

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    rows: u64,
}

impl Emitter<'_> {
    async fn rows(&mut self, rows: Vec<Vec<Value>>) -> Result<u64, DriverError> {
        let count = rows.len() as u64;
        let mut rows = rows.into_iter().peekable();
        while rows.peek().is_some() {
            let batch: Vec<Vec<Value>> = rows.by_ref().take(BATCH_ROWS).collect();
            self.send(ResultEvent::Rows(batch)).await?;
        }
        self.rows += count;
        Ok(count)
    }

    async fn finished(&mut self, rows: u64) -> Result<(), DriverError> {
        self.send(ResultEvent::ResultSetFinished {
            retained: rows,
            total_rows: Some(rows),
            truncation: Truncation::Complete,
        })
        .await
    }

    /// A consumer that went away ends the read: no further page is asked
    /// for.
    async fn send(&mut self, event: ResultEvent) -> Result<(), DriverError> {
        match self.sink.accept(event).await {
            SinkFlow::Continue => Ok(()),
            SinkFlow::ConsumerGone => Err(DriverError::Cancelled),
        }
    }
}
