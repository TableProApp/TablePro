//! Emptying a table and making and dropping a keyspace, as the sidebar
//! plans them, against both servers.

use tablepro_core::ddl::{
    self as catalog, DatabaseDraft, DdlPlan, DropDatabaseOptions, KeyspaceReplication, TruncateTableOptions,
};
use tablepro_core::meta::ObjectScope;
use tablepro_core::{ConnectTarget, Connection, DatabaseDriver, DriverError, TableRef, Value, WorkspaceSettings};
use tablepro_driver_cassandra::CassandraDriver;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, CassandraServer, KEYSPACE, ScyllaServer, Server, connect, count, fixture_options, scalar, setup, start,
    table, within,
};

const MADE: &str = "tablepro_made";

async fn run(connection: &dyn Connection, plan: DdlPlan, table: TableRef) -> Result<(), DriverError> {
    connection
        .write_batch(&plan.into_write_batch(table), within(CALL))
        .await
        .map(|_| ())
}

async fn keyspace_names(connection: &dyn Connection) -> Vec<String> {
    connection
        .list_databases(within(CALL))
        .await
        .expect("the keyspaces")
        .into_iter()
        .map(|keyspace| keyspace.name)
        .collect()
}

/// TRUNCATE keeps the table and drops every row, on every node.
async fn a_truncate_empties_the_table<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE tablepro.notes (id int PRIMARY KEY, body text)",
            "INSERT INTO tablepro.notes (id, body) VALUES (1, 'a')",
            "INSERT INTO tablepro.notes (id, body) VALUES (2, 'b')",
        ],
    )
    .await;
    let dialect = connection.dialect();
    let plan = catalog::plan_truncate_table(dialect.as_ref(), &table("notes"), &TruncateTableOptions::default())
        .expect("a plan");

    run(connection.as_ref(), plan, table("notes"))
        .await
        .expect("the truncate");

    assert_eq!(
        count(connection.as_ref(), "SELECT count(*) FROM tablepro.notes").await,
        0
    );
    let objects = connection
        .list_objects(&ObjectScope::Schema(KEYSPACE.to_owned()), within(CALL))
        .await
        .expect("the tables");
    assert!(objects.iter().any(|object| object.name == "notes"), "{objects:?}");
}

/// A keyspace placed in every data centre the node knows, made and
/// dropped through the save path.
async fn a_keyspace_is_made_in_each_data_centre_and_dropped<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    let dialect = connection.dialect();
    let offered = catalog::catalog_capabilities(dialect.as_ref());
    let choices = connection
        .fetch_database_choices(within(CALL))
        .await
        .expect("the choices");
    let mut draft = DatabaseDraft::named(MADE);
    draft.replication = Some(KeyspaceReplication::NetworkTopology {
        factors: choices.data_centers.iter().map(|centre| (centre.clone(), 1)).collect(),
    });
    draft.durable_writes = false;
    draft.tablets = offered.database_fields.tablets.then_some(false);
    let created = catalog::plan_create_database(dialect.as_ref(), &draft).expect("a plan");

    run(connection.as_ref(), created, TableRef::new(Some(MADE.to_owned()), ""))
        .await
        .expect("the keyspace is made");
    let listed = keyspace_names(connection.as_ref()).await;
    let durable = scalar(
        connection.as_ref(),
        "SELECT durable_writes FROM system_schema.keyspaces WHERE keyspace_name = 'tablepro_made'",
    )
    .await;
    let dropped = catalog::plan_drop_database(dialect.as_ref(), MADE, &DropDatabaseOptions::default()).expect("a plan");
    run(connection.as_ref(), dropped, TableRef::new(Some(MADE.to_owned()), ""))
        .await
        .expect("the keyspace is dropped");

    assert!(!choices.data_centers.is_empty());
    assert!(listed.iter().any(|name| name == MADE), "{listed:?}");
    assert_eq!(durable, Value::Bool(false));
    let after = keyspace_names(connection.as_ref()).await;
    assert!(!after.iter().any(|name| name == MADE), "{after:?}");
}

async fn a_keyspace_the_server_lacks_is_not_found<S: Server>() {
    let fixture = start::<S>().await;
    let mut options = fixture_options(&fixture, WorkspaceSettings::workspace(false));
    if let ConnectTarget::Network(target) = &mut options.target {
        target.database = Some("tablepro_gone".to_owned());
    }

    let refused = CassandraDriver.connect(options, CancellationToken::new()).await;

    assert!(
        matches!(&refused, Err(DriverError::DatabaseNotFound { database }) if database == "tablepro_gone"),
        "{:?}",
        refused.as_ref().err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_truncate_empties_the_table() {
    a_truncate_empties_the_table::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_truncate_empties_the_table() {
    a_truncate_empties_the_table::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_keyspace_is_made_and_dropped() {
    a_keyspace_is_made_in_each_data_centre_and_dropped::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_keyspace_is_made_and_dropped() {
    a_keyspace_is_made_in_each_data_centre_and_dropped::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_missing_keyspace_is_not_found() {
    a_keyspace_the_server_lacks_is_not_found::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_missing_keyspace_is_not_found() {
    a_keyspace_the_server_lacks_is_not_found::<ScyllaServer>().await;
}
