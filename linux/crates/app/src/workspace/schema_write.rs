use std::sync::Arc;

use tablepro_core::ddl::{BuildDdlError, DdlDialect, DdlOperation, DdlPlan};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{WriteKind, WriteReport};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

/// Plan a schema change with the dialect of the connection that runs
/// it, and run the plan as one write. The statements come back whether
/// or not the write went through, for the history. `operation` is what
/// a connection with no DDL dialect refuses.
pub(crate) async fn run_schema_plan<P>(
    session: Arc<Session>,
    table: TableRef,
    operation: DdlOperation,
    cancel: &CancellationToken,
    plan: P,
) -> Result<(Vec<String>, Result<WriteReport, OperationError>), OperationError>
where
    P: Fn(&dyn DdlDialect, &TableRef) -> Result<DdlPlan, BuildDdlError> + Send + Sync,
{
    session
        .run_cancellable(
            OperationKind::Save(WriteKind::SchemaChanges),
            cancel,
            move |lease, options| {
                let table = table.clone();
                let dialect = lease.dialect();
                let planned = match dialect.ddl() {
                    Some(ddl) => plan(ddl, &table).map_err(SqlBuildError::from),
                    None => Err(SqlBuildError::from(BuildDdlError::Unsupported(operation))),
                };
                async move {
                    let plan = planned?;
                    let statements: Vec<String> = plan.sql().into_iter().map(str::to_owned).collect();
                    let written = lease.write_batch(&plan.into_write_batch(table), options).await;
                    Ok((statements, written.map_err(OperationError::from)))
                }
            },
        )
        .await
}
