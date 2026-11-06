use std::sync::Arc;

use tablepro_core::ddl::{BuildDdlError, DdlDialect, DdlOperation, DdlPlan};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{CommitResolution, WriteKind, WriteReport};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use super::workspace_handle::{HistoryEntry, record, resolve_commit};

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
    run_plan(
        &session,
        WriteKind::SchemaChanges,
        table,
        cancel,
        move |dialect, table| match dialect.ddl() {
            Some(ddl) => plan(ddl, table),
            None => Err(BuildDdlError::Unsupported(operation)),
        },
    )
    .await
}

/// A table emptied or dropped, or a schema or database created or
/// dropped.
pub(crate) struct CatalogChange {
    /// What the session runs the write as. The batch is wrapped as the
    /// plan's own kind says.
    pub kind: WriteKind,
    /// What the batch names: the table, or a schema or database as a
    /// schema with no table.
    pub target: TableRef,
    pub history: HistoryEntry,
}

/// Run a catalog change planned with the dialect of the connection that
/// runs it, ask the server about a commit whose answer was lost, and
/// record it in the history however it went, as a save is.
pub(crate) async fn run_catalog_change<P>(
    session: Arc<Session>,
    change: CatalogChange,
    cancel: &CancellationToken,
    plan: P,
) -> Result<(), OperationError>
where
    P: Fn(&dyn SqlDialect, &TableRef) -> Result<DdlPlan, BuildDdlError> + Send + Sync,
{
    let CatalogChange { kind, target, history } = change;
    let (statements, written) = run_plan(&session, kind, target, cancel, plan)
        .await
        .unwrap_or_else(|error| (Vec::new(), Err(error)));
    let resolution = resolve_commit(&session, &written).await;
    record(history, statements, &written, resolution.as_ref()).await;
    landed(written, resolution)
}

/// A database names no table, so its batch names it as a schema.
pub(crate) fn database_target(database: &str) -> TableRef {
    TableRef::new(Some(database.to_owned()), "")
}

fn landed(
    written: Result<WriteReport, OperationError>,
    resolution: Option<Result<CommitResolution, OperationError>>,
) -> Result<(), OperationError> {
    match (written, resolution) {
        (Ok(_), _) | (Err(_), Some(Ok(CommitResolution::Applied))) => Ok(()),
        (Err(error), _) => Err(error),
    }
}

async fn run_plan<P>(
    session: &Session,
    kind: WriteKind,
    target: TableRef,
    cancel: &CancellationToken,
    plan: P,
) -> Result<(Vec<String>, Result<WriteReport, OperationError>), OperationError>
where
    P: Fn(&dyn SqlDialect, &TableRef) -> Result<DdlPlan, BuildDdlError> + Send + Sync,
{
    session
        .run_cancellable(OperationKind::Save(kind), cancel, move |lease, options| {
            let target = target.clone();
            let dialect = lease.dialect();
            let planned = plan(&*dialect, &target).map_err(SqlBuildError::from);
            async move {
                let plan = planned?;
                let statements: Vec<String> = plan.sql().into_iter().map(str::to_owned).collect();
                let written = lease.write_batch(&plan.into_write_batch(target), options).await;
                Ok((statements, written.map_err(OperationError::from)))
            }
        })
        .await
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::DropDatabaseOptions;
    use tablepro_core::{CommitToken, DriverError, LossPhase};

    use super::*;

    fn postgres() -> tablepro_driver_postgres::PgDialect {
        tablepro_driver_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
    }

    #[test]
    fn a_database_batch_runs_outside_a_transaction_and_names_the_database() {
        let plan = tablepro_core::ddl::plan_drop_database(&postgres(), "shop", &DropDatabaseOptions::default())
            .expect("PostgreSQL drops a database");

        let batch = plan.into_write_batch(database_target("shop"));

        assert_eq!(batch.kind, WriteKind::DatabaseChanges);
        assert_eq!(batch.table, TableRef::new(Some("shop".to_owned()), ""));
    }

    #[test]
    fn a_lost_commit_the_server_applied_landed() {
        let lost = || {
            Err(OperationError::from(DriverError::CommitOutcomeUnknown {
                token: Some(CommitToken::PostgresXid {
                    xid: 4,
                    legacy_txid: false,
                }),
                source: Box::new(DriverError::ConnectionLost {
                    during: LossPhase::Commit,
                }),
            }))
        };

        assert_eq!(landed(lost(), Some(Ok(CommitResolution::Applied))), Ok(()));
        assert!(landed(lost(), Some(Ok(CommitResolution::NotApplied))).is_err());
        assert!(landed(lost(), None).is_err());
        assert_eq!(landed(Ok(WriteReport::new(vec![None])), None), Ok(()));
    }
}
