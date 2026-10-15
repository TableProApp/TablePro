use std::sync::Arc;

use tablepro_core::export::{ExportError, RowPage};
use tablepro_core::{Connection, DriverError, OperationControl, Value};
use tokio_util::sync::CancellationToken;

use super::{StatementCursor, StatementTarget};

pub(crate) fn query_cursor_export_factory(
    connection: Arc<dyn Connection>,
    query: crate::ui::export_dialog::StreamExportQuery,
) -> crate::ui::export_dialog::PageFetcherFactory {
    let runner = export_page_runner();
    query_cursor_export_factory_for_target(
        StatementTarget::Pool(connection),
        query.sql,
        query.params,
        query.timeout_secs,
        runner,
    )
}

pub(crate) fn query_cursor_export_factory_for_target(
    target: StatementTarget,
    sql: String,
    params: Vec<Value>,
    timeout_secs: u32,
    runner: crate::services::export_pages::PageRunner,
) -> crate::ui::export_dialog::PageFetcherFactory {
    Arc::new(move |cancel| {
        let source = ExportPageSource {
            target: target.clone(),
            cursor: Arc::new(tokio::sync::Mutex::new(None)),
            finished: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            runner: runner.clone(),
            sql: sql.clone(),
            params: params.clone(),
            timeout_secs,
        };
        let fetch = export_page_fetcher(source.clone(), cancel);
        let finish = export_page_finalizer(source.cursor, source.finished, source.runner);
        crate::ui::export_dialog::PageFetcher::new(fetch, finish)
    })
}

fn export_page_runner() -> crate::services::export_pages::PageRunner {
    Arc::new(|future| {
        let (reply, answer) = async_channel::bounded(1);
        relm4::spawn(async move {
            let _ = reply.send(future.await).await;
        });
        answer
            .recv_blocking()
            .unwrap_or_else(|_| Err(ExportError::Source("the export was interrupted".into())))
    })
}

#[derive(Clone)]
struct ExportPageSource {
    target: StatementTarget,
    cursor: Arc<tokio::sync::Mutex<Option<StatementCursor>>>,
    finished: Arc<std::sync::atomic::AtomicBool>,
    runner: crate::services::export_pages::PageRunner,
    sql: String,
    params: Vec<Value>,
    timeout_secs: u32,
}

fn export_page_fetcher(
    source: ExportPageSource,
    cancel: CancellationToken,
) -> impl FnMut() -> Result<Option<RowPage>, ExportError> + Send {
    let ExportPageSource {
        target,
        cursor,
        finished,
        runner,
        sql: query_sql,
        params: query_params,
        timeout_secs,
    } = source;
    move || {
        if finished.load(std::sync::atomic::Ordering::Acquire) {
            return Ok(None);
        }
        let shared = cursor.clone();
        let done = finished.clone();
        let query_target = target.clone();
        let sql = query_sql.clone();
        let params = query_params.clone();
        let control = OperationControl::new(
            cancel.clone(),
            crate::services::operation_control::deadline_for(timeout_secs),
        );
        let future = Box::pin(async move {
            let mut state = shared.lock().await;
            if state.is_none() {
                *state = query_target
                    .open_query_cursor(&sql, &params, &control)
                    .await
                    .map_err(export_driver_error)?;
            }
            let Some(cursor) = state.as_ref() else {
                return Err(ExportError::Source("query cursor streaming is unavailable".into()));
            };
            let page = match cursor.fetch_page(&control).await {
                Ok(page) => page,
                Err(error) => {
                    let result = export_driver_error(error);
                    close_export_cursor_after_error(&mut state, false).await;
                    done.store(true, std::sync::atomic::Ordering::Release);
                    return Err(result);
                }
            };
            if page.result.truncated {
                close_export_cursor_after_error(&mut state, true).await;
                done.store(true, std::sync::atomic::Ordering::Release);
                return Err(ExportError::Source(
                    "a query export page exceeded the result limits".into(),
                ));
            }
            if !page.has_next_page {
                close_export_cursor(&mut state, true).await?;
                done.store(true, std::sync::atomic::Ordering::Release);
            }
            Ok(page.result.rows)
        });
        let rows = runner(future)?;
        Ok(Some(rows))
    }
}

fn export_page_finalizer(
    cursor: Arc<tokio::sync::Mutex<Option<StatementCursor>>>,
    finished: Arc<std::sync::atomic::AtomicBool>,
    runner: crate::services::export_pages::PageRunner,
) -> impl FnOnce() -> Result<(), ExportError> + Send {
    move || {
        let future = Box::pin(async move {
            let mut state = cursor.lock().await;
            close_export_cursor(&mut state, true).await?;
            finished.store(true, std::sync::atomic::Ordering::Release);
            Ok(Vec::new())
        });
        runner(future).map(|_| ())
    }
}

async fn close_export_cursor(cursor: &mut Option<StatementCursor>, close_cursor: bool) -> Result<(), ExportError> {
    let Some(cursor) = cursor.take() else {
        return Ok(());
    };
    cursor.finish(close_cursor).await.map_err(export_driver_error)
}

async fn close_export_cursor_after_error(cursor: &mut Option<StatementCursor>, close_cursor: bool) {
    if let Err(error) = close_export_cursor(cursor, close_cursor).await {
        tracing::warn!(%error, "query export cursor cleanup failed");
    }
}

fn export_driver_error(error: DriverError) -> ExportError {
    match error {
        DriverError::Cancelled => ExportError::Cancelled,
        error => ExportError::Source(crate::ui::error_text::driver_message(&error)),
    }
}
