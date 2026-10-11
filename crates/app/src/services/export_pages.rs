use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use tablepro_core::export::{ExportError, RowPage};
use tablepro_core::{ColumnInfo, Connection, FilterSet, OperationControl};
use tokio_util::sync::CancellationToken;

use crate::services::browse_query::{BrowseTarget, PageQuery};

pub(crate) const EXPORT_PAGE_ROWS: u64 = 5_000;

pub(crate) type PageFuture = Pin<Box<dyn Future<Output = Result<RowPage, ExportError>> + Send>>;
pub(crate) type PageRunner = Arc<dyn Fn(PageFuture) -> Result<RowPage, ExportError> + Send + Sync>;

#[derive(Clone)]
pub(crate) struct PagePlan {
    pub driver_id: String,
    pub schema: Option<String>,
    pub table: String,
    pub columns: Vec<ColumnInfo>,
    pub filter: FilterSet,
    pub sort: Option<(usize, bool)>,
    pub timeout_secs: u32,
}

fn page_future(
    conn: Arc<dyn Connection>,
    plan: &PagePlan,
    offset: u64,
    cancel: &CancellationToken,
) -> Result<PageFuture, ExportError> {
    let target = BrowseTarget {
        driver_id: &plan.driver_id,
        schema: plan.schema.as_deref(),
        table: &plan.table,
        columns: &plan.columns,
        filter: &plan.filter,
        hidden_columns: None,
    };
    let query = target
        .page(offset, EXPORT_PAGE_ROWS, plan.sort, None)
        .map_err(ExportError::Source)?;
    let schema = plan.schema.clone();
    let table = plan.table.clone();
    let deadline = crate::services::operation_control::deadline_for(plan.timeout_secs);
    let control = OperationControl::new(cancel.clone(), deadline);
    Ok(Box::pin(async move {
        let result = match query {
            PageQuery::Native => {
                conn.fetch_rows_controlled(schema.as_deref(), &table, offset, EXPORT_PAGE_ROWS, &control)
                    .await
            }
            PageQuery::Sql(query) => conn.query_params_controlled(&query.sql, &query.params, &control).await,
        }
        .map_err(|error| ExportError::Source(crate::ui::error_text::driver_message(&error)))?;
        if result.truncated {
            return Err(ExportError::Source("a page of rows exceeded the result limits".into()));
        }
        Ok(result.rows)
    }))
}

pub(crate) fn page_fetcher(
    conn: Arc<dyn Connection>,
    plan: PagePlan,
    run: PageRunner,
    cancel: CancellationToken,
) -> impl FnMut() -> Result<Option<RowPage>, ExportError> + Send {
    let mut offset = 0u64;
    let mut finished = false;
    move || {
        if finished {
            return Ok(None);
        }
        let rows = run(page_future(conn.clone(), &plan, offset, &cancel)?)?;
        finished = (rows.len() as u64) < EXPORT_PAGE_ROWS;
        offset += rows.len() as u64;
        Ok((!rows.is_empty()).then_some(rows))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

    async fn table_with(rows: u64) -> (tempfile::TempDir, Arc<dyn Connection>) {
        let directory = tempfile::tempdir().unwrap();
        let connection = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: directory.path().join("pages.db").to_string_lossy().into_owned(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = crate::services::operation_control::bounded(30);
        connection
            .execute_controlled("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &control)
            .await
            .unwrap();
        connection
            .execute_controlled(
                &format!(
                    "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < {rows}) \
                 INSERT INTO t (id, name) SELECT i, 'row ' || i FROM n"
                ),
                &control,
            )
            .await
            .unwrap();
        (directory, Arc::from(connection))
    }

    fn plan() -> PagePlan {
        PagePlan {
            driver_id: "sqlite".into(),
            schema: None,
            table: "t".into(),
            columns: Vec::new(),
            filter: FilterSet::default(),
            sort: None,
            timeout_secs: 0,
        }
    }

    fn runner(runtime: &Arc<tokio::runtime::Runtime>) -> PageRunner {
        let runtime = runtime.clone();
        Arc::new(move |future| runtime.block_on(future))
    }

    fn runtime() -> Arc<tokio::runtime::Runtime> {
        Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .unwrap(),
        )
    }

    #[test]
    fn pages_cover_the_table_once_in_key_order_and_stop() {
        let runtime = runtime();
        let total = EXPORT_PAGE_ROWS * 2 + 7;
        let (_directory, connection) = runtime.block_on(table_with(total));
        let mut next = page_fetcher(connection, plan(), runner(&runtime), CancellationToken::new());
        let mut seen = Vec::new();
        while let Some(rows) = next().unwrap() {
            seen.extend(rows.into_iter().map(|row| row[0].clone()));
        }
        let expected: Vec<Value> = (1..=total as i64).map(Value::Int).collect();
        assert_eq!(seen, expected);
        assert!(next().unwrap().is_none());
    }

    #[test]
    fn an_exact_multiple_of_the_page_size_ends_on_an_empty_page() {
        let runtime = runtime();
        let (_directory, connection) = runtime.block_on(table_with(EXPORT_PAGE_ROWS));
        let mut next = page_fetcher(connection, plan(), runner(&runtime), CancellationToken::new());
        assert_eq!(next().unwrap().unwrap().len() as u64, EXPORT_PAGE_ROWS);
        assert!(next().unwrap().is_none());
    }

    #[test]
    fn a_missing_table_is_reported_to_the_exporter() {
        let runtime = runtime();
        let (_directory, connection) = runtime.block_on(table_with(1));
        let mut missing = plan();
        missing.table = "absent".into();
        let mut next = page_fetcher(connection, missing, runner(&runtime), CancellationToken::new());
        assert!(matches!(next(), Err(ExportError::Source(_))));
    }

    #[test]
    fn a_filter_limits_the_exported_rows() {
        let runtime = runtime();
        let (_directory, connection) = runtime.block_on(table_with(30));
        let columns = runtime
            .block_on(connection.fetch_columns_controlled(None, "t", &crate::services::operation_control::bounded(30)))
            .unwrap();
        let mut filtered = plan();
        filtered.filter = FilterSet {
            rules: vec![tablepro_core::FilterRule {
                column: "id".into(),
                op: tablepro_core::FilterOp::Gt,
                value: Some(tablepro_core::FilterValue::Single("25".into())),
            }],
            ..FilterSet::default()
        };
        filtered.columns = columns;
        let mut next = page_fetcher(connection, filtered, runner(&runtime), CancellationToken::new());
        assert_eq!(next().unwrap().unwrap().len(), 5);
    }

    #[test]
    fn a_table_larger_than_one_page_exports_to_a_complete_csv_file() {
        use tablepro_core::export::{CsvOptions, ResultExport, ResultFormat, write_paged_file};
        let runtime = runtime();
        let total = EXPORT_PAGE_ROWS * 2 + 3;
        let (directory, connection) = runtime.block_on(table_with(total));
        let columns = runtime
            .block_on(connection.fetch_columns_controlled(None, "t", &crate::services::operation_control::bounded(30)))
            .unwrap();
        let next = page_fetcher(connection, plan(), runner(&runtime), CancellationToken::new());
        let path = directory.path().join("all.csv");
        let options = CsvOptions::default();
        write_paged_file(
            &path,
            &columns,
            total as usize,
            &ResultExport {
                format: ResultFormat::Csv,
                csv: &options,
                sql: None,
            },
            next,
            || false,
            |_| {},
        )
        .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len() as u64, total + 1);
        assert_eq!(lines[0], "id,name");
        assert_eq!(lines[1], "1,row 1");
        assert_eq!(lines[total as usize], format!("{total},row {total}"));
    }
}
