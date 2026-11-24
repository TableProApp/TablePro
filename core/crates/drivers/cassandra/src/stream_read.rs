//! Every row of a read into a sink, page by page, for an export.

use scylla::response::PagingState;
use scylla::statement::unprepared::Statement as CqlStatement;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{
    DriverError, LossPhase, ReadEmitter, ReadOnlyRefusal, ReadStatement, ResultSink, StopRequest, StreamSummary, Value,
};

use crate::call::stoppable;
use crate::errors::execution_error;
use crate::rows::{ColumnsRead, MAX_PAGE_ROWS, next_state, page_size};
use crate::session::CqlLink;

/// CQL has no read-only session, so user SQL that is not a plain read is
/// refused before it is sent; generated reads are SELECTs. Each page is
/// asked for once the sink took the last.
pub(crate) async fn stream(
    link: &CqlLink,
    read: &ReadStatement,
    sink: &mut dyn ResultSink,
    stop: &StopRequest,
) -> Result<StreamSummary, DriverError> {
    let mut emitter = ReadEmitter::new(sink);
    match read {
        ReadStatement::Generated(statement) => {
            let mut paging = PagingState::start();
            let mut columns: Option<ColumnsRead> = None;
            loop {
                let page = link.page(statement, page_size(MAX_PAGE_ROWS), paging);
                let (result, response) = stoppable(stop, page).await?;
                let page_rows = result
                    .into_rows_result()
                    .map_err(|error| DriverError::Protocol(error.to_string()))?;
                if columns.is_none() {
                    let read = ColumnsRead::of(page_rows.column_specs());
                    emitter.start(read.columns.clone()).await?;
                    columns = Some(read);
                }
                let decoded = columns
                    .as_ref()
                    .map_or(Ok(Vec::new()), |read| read.decode(&page_rows))?;
                emit_page(&mut emitter, decoded).await?;
                match next_state(response) {
                    Some(next) => paging = next,
                    None => break,
                }
            }
            emitter.finish().await?;
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
    Ok(StreamSummary::new(emitter.rows()))
}

async fn user_statement(
    link: &CqlLink,
    text: &str,
    emitter: &mut ReadEmitter<'_>,
    stop: &StopRequest,
) -> Result<(), DriverError> {
    let mut statement = CqlStatement::new(text);
    statement.set_page_size(page_size(MAX_PAGE_ROWS));
    let mut paging = PagingState::start();
    let mut columns: Option<ColumnsRead> = None;
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
            emitter.start(read.columns.clone()).await?;
            columns = Some(read);
        }
        let decoded = columns
            .as_ref()
            .map_or(Ok(Vec::new()), |read| read.decode(&page_rows))?;
        emit_page(emitter, decoded).await?;
        match next_state(response) {
            Some(next) => paging = next,
            None => return emitter.finish().await,
        }
    }
}

// Nothing is carried to the next page: each page's last rows go out before it is asked for.
async fn emit_page(emitter: &mut ReadEmitter<'_>, rows: Vec<Vec<Value>>) -> Result<(), DriverError> {
    for row in rows {
        emitter.row(row).await?;
    }
    emitter.flush().await
}
