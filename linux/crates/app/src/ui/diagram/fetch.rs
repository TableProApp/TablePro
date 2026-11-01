use std::sync::Arc;

use futures::StreamExt;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::model::{SchemaDiagram, TableRead};
use crate::ui::tab_load::LoadFailure;

/// How many tables are read at once. The workspace's pool has four
/// connections, so a schema of hundreds of tables leaves the others for
/// the tabs and the sidebar.
pub(crate) const READS_AT_ONCE: usize = 2;

/// How far a read has got: tables read, of how many.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ReadProgress {
    pub done: usize,
    pub total: usize,
}

/// Read every table of `schema`, or with `None` of the connection's
/// default one, which is how an engine without schemas names its own:
/// `READS_AT_ONCE` at a time, each table's columns, keys and indexes from
/// one connection lease. The table list is read here too rather than
/// through the catalog, whose reads Stop cannot end, and since a change
/// made while no diagram was open marks no list stale. `cancel` stops
/// the read, and with it the statements on the server. A table that
/// fails fails the whole read, rather than draw the schema without it
/// as if it were not there.
pub(crate) async fn read_diagram(
    session: Arc<Session>,
    schema: Option<String>,
    cancel: CancellationToken,
    progress: watch::Sender<ReadProgress>,
) -> Result<SchemaDiagram, LoadFailure> {
    let scope = match schema {
        Some(schema) => ObjectScope::Schema(schema),
        None => ObjectScope::DefaultSchema,
    };
    let objects = session
        .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
            let scope = scope.clone();
            async move { Ok(lease.list_objects(&scope, options).await?) }
        })
        .await
        .map_err(|error| LoadFailure::Schema(Arc::new(error)))?;
    let tables: Vec<TableRef> = objects
        .iter()
        .filter(|object| object.kind.is_structure_editable())
        .map(|object| TableRef::new(object.schema.clone(), object.name.clone()))
        .collect();
    let total = tables.len();
    progress.send_replace(ReadProgress { done: 0, total });
    let mut reads = futures::stream::iter(
        tables
            .into_iter()
            .map(|table| read_table(session.clone(), table, &cancel)),
    )
    .buffer_unordered(READS_AT_ONCE);
    let mut found = Vec::with_capacity(total);
    while let Some(read) = reads.next().await {
        found.push(read?);
        progress.send_replace(ReadProgress {
            done: found.len(),
            total,
        });
    }
    Ok(SchemaDiagram::build(found))
}

async fn read_table(
    session: Arc<Session>,
    table: TableRef,
    cancel: &CancellationToken,
) -> Result<TableRead, LoadFailure> {
    session
        .run_cancellable(OperationKind::Metadata, cancel, move |lease, options| {
            let table = table.clone();
            async move {
                let columns = lease.fetch_columns(&table, options.clone()).await?;
                let foreign_keys = lease.fetch_foreign_keys(&table, options.clone()).await?;
                let indexes = lease.fetch_indexes(&table, options).await?;
                Ok(TableRead {
                    table,
                    columns,
                    foreign_keys,
                    indexes,
                })
            }
        })
        .await
        .map_err(|error| {
            if error != OperationError::Cancelled {
                tracing::warn!(category = ?error.category(), "a table of the diagram could not be read");
            }
            LoadFailure::Schema(Arc::new(error))
        })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::DriverError;
    use tablepro_core::meta::{ObjectInfo, ObjectKind};
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::super::model::tests::{column, key};
    use super::*;
    use crate::test_support::{FakeSession, finish_on_main};

    const WAIT: Duration = Duration::from_secs(10);

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("sales".to_owned()),
            name: name.to_owned(),
            kind,
            parent_table: None,
        }
    }

    fn sales() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.list_objects.always(FakeReply::ok(vec![
            object("orders", ObjectKind::Table),
            object("customers", ObjectKind::Table),
            object("order_totals", ObjectKind::View),
        ]));
        script
            .fetch_columns
            .when_sql_contains(
                "orders",
                FakeReply::ok(vec![column("id", true, false), column("customer_id", false, false)]),
            )
            .always(FakeReply::ok(vec![column("id", true, false)]));
        script
            .fetch_foreign_keys
            .when_sql_contains(
                "orders",
                FakeReply::ok(vec![key(
                    "orders_customer",
                    &["customer_id"],
                    Some("sales"),
                    "customers",
                    &["id"],
                )]),
            )
            .always(FakeReply::ok(Vec::new()));
        script.fetch_indexes.always(FakeReply::ok(Vec::new()));
        script
    }

    fn read(script: ConnectionScript, cancel: CancellationToken) -> (Result<SchemaDiagram, LoadFailure>, ReadProgress) {
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let (progress, watching) = watch::channel(ReadProgress::default());
        let running = runtime.tasks().spawn_task(read_diagram(
            fake.session.clone(),
            Some("sales".to_owned()),
            cancel,
            progress,
        ));
        let outcome = finish_on_main(WAIT, running).expect("the read ends");
        let last = *watching.borrow();
        runtime.shutdown();
        (outcome.expect("the read ran to its end"), last)
    }

    #[gtk4::test]
    fn the_schemas_tables_are_read_with_their_keys_and_views_are_left_out() {
        let (diagram, progress) = read(sales(), CancellationToken::new());

        let diagram = diagram.expect("a diagram");
        let names: Vec<&str> = diagram.tables.iter().map(|table| table.table.name.as_str()).collect();
        assert_eq!(names, ["customers", "orders"]);
        assert_eq!(diagram.relations.len(), 1);
        assert_eq!(progress, ReadProgress { done: 2, total: 2 });
    }

    #[gtk4::test]
    fn one_table_that_fails_fails_the_read() {
        let mut script = sales();
        script.fetch_indexes = Default::default();
        script
            .fetch_indexes
            .when_sql_contains("customers", FakeReply::err(DriverError::server("permission denied")))
            .always(FakeReply::ok(Vec::new()));

        let (diagram, _) = read(script, CancellationToken::new());

        let failure = diagram.expect_err("a failed read");
        assert!(failure.message().contains("permission denied"), "{}", failure.message());
    }

    #[gtk4::test]
    fn stop_ends_the_read_with_nothing() {
        let cancel = CancellationToken::new();
        cancel.cancel();

        let (diagram, _) = read(sales(), cancel);

        assert!(
            matches!(diagram, Err(LoadFailure::Schema(ref error)) if **error == OperationError::Cancelled),
            "{diagram:?}"
        );
    }

    /// Stop reaches the server's listing too, not only the table reads.
    #[gtk4::test]
    fn stop_ends_a_listing_still_running_on_the_server() {
        let mut script = sales();
        script.list_objects = Default::default();
        script.list_objects.always(FakeReply::UntilStopped);
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let cancel = CancellationToken::new();
        let (progress, _watching) = watch::channel(ReadProgress::default());
        let running = runtime.tasks().spawn_task(read_diagram(
            fake.session.clone(),
            Some("sales".to_owned()),
            cancel.clone(),
            progress,
        ));
        let listed = || tablepro_test_support::CallCounters::get(&fake.connection.counters().list_objects);
        crate::test_support::wait_until(WAIT, || listed() > 0).expect("the listing to start");

        cancel.cancel();
        let outcome = finish_on_main(WAIT, running)
            .expect("the read ends")
            .expect("the read ran");

        assert!(
            matches!(outcome, Err(LoadFailure::Schema(ref error)) if **error == OperationError::Cancelled),
            "{outcome:?}"
        );
        let calls = fake.connection.observed_cancels("list_objects");
        assert!(
            calls.last().is_some_and(CancellationToken::is_cancelled),
            "the listing kept running"
        );
        runtime.shutdown();
    }
}
