//! What the sidebar and the structure tab read: keyspaces, tables and
//! views, a table's key, and the CREATE statements the server's schema
//! tables describe.

use tablepro_core::meta::{ObjectKind, ObjectScope, RowIdentity};
use tablepro_core::{Connection, TlsConfig, Value, WorkspaceSettings};
use tablepro_test_fixtures::CassandraFlavour;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{
    CALL, CassandraServer, KEYSPACE, ScyllaServer, Server, connect, connect_with, direct, options_over, password, rows,
    setup, start, table, within,
};

const ORDERS: &str = "CREATE TABLE tablepro.orders (customer int, placed timestamp, total decimal, note text, \
                      PRIMARY KEY ((customer), placed)) WITH CLUSTERING ORDER BY (placed DESC) \
                      AND default_time_to_live = 86400";
const NOTE_INDEX: &str = "CREATE INDEX orders_note ON tablepro.orders (note)";
const BY_TOTAL: &str = "CREATE MATERIALIZED VIEW tablepro.orders_by_total AS SELECT * FROM tablepro.orders \
                        WHERE customer IS NOT NULL AND placed IS NOT NULL AND total IS NOT NULL \
                        PRIMARY KEY (total, customer, placed)";
// A lightweight transaction gives a ScyllaDB table with tablets a Paxos
// state table, which the sidebar must not show.
const LWT: &str = "INSERT INTO tablepro.orders (customer, placed, total) VALUES (1, '2024-01-01', 1.5) IF NOT EXISTS";

async fn schema(connection: &dyn Connection) {
    setup(connection, &[ORDERS, NOTE_INDEX, BY_TOTAL, LWT]).await;
}

async fn the_sidebar_lists_keyspaces_tables_and_views<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    schema(connection.as_ref()).await;

    let schemas = connection.list_schemas(within(CALL)).await.expect("the keyspaces");
    let objects = connection
        .list_objects(&ObjectScope::Schema(KEYSPACE.to_owned()), within(CALL))
        .await
        .expect("the tables");

    let tablepro = schemas.iter().find(|schema| schema.name == KEYSPACE).expect("tablepro");
    assert!(tablepro.is_default && !tablepro.is_system);
    let system = schemas
        .iter()
        .find(|schema| schema.name == "system_schema")
        .expect("system_schema");
    assert!(system.is_system);
    let listed: Vec<(&str, ObjectKind)> = objects
        .iter()
        .map(|object| (object.name.as_str(), object.kind))
        .collect();
    assert_eq!(
        listed,
        [
            ("orders", ObjectKind::Table),
            ("orders_by_total", ObjectKind::MaterializedView)
        ]
    );
}

async fn a_table_is_keyed_by_its_primary_key_and_a_view_is_read_only<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    schema(connection.as_ref()).await;

    let columns = connection
        .fetch_columns(&table("orders"), within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(&table("orders"), within(CALL))
        .await
        .expect("the identity");
    let view_columns = connection
        .fetch_columns(&table("orders_by_total"), within(CALL))
        .await
        .expect("the view's columns");
    let view_identity = connection
        .row_identity(&table("orders_by_total"), within(CALL))
        .await
        .expect("the view's identity");

    let shape: Vec<(&str, bool)> = columns
        .iter()
        .map(|column| (column.name.as_str(), column.primary_key))
        .collect();
    assert_eq!(
        shape,
        [("customer", true), ("placed", true), ("note", false), ("total", false)]
    );
    assert_eq!(
        identity,
        RowIdentity::UniqueKey {
            columns: vec!["customer".to_owned(), "placed".to_owned()]
        }
    );
    assert!(
        view_columns.iter().all(|column| !column.primary_key),
        "{view_columns:?}"
    );
    assert_eq!(view_identity, RowIdentity::Unordered);
}

async fn the_create_script_rebuilds_the_table_it_was_read_from<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[ORDERS, NOTE_INDEX]).await;
    let before = connection
        .fetch_columns(&table("orders"), within(CALL))
        .await
        .expect("the columns");

    let definition = connection
        .fetch_table_definition(&table("orders"), within(CALL))
        .await
        .expect("the definition");
    let source = definition.source.expect("the server's own description");
    assert!(
        source
            .create_statement
            .starts_with("CREATE TABLE \"tablepro\".\"orders\" (\n"),
        "{}",
        source.create_statement
    );
    assert!(
        source
            .create_statement
            .contains("PRIMARY KEY (\"customer\", \"placed\")"),
        "{}",
        source.create_statement
    );
    assert!(
        source
            .create_statement
            .contains("CLUSTERING ORDER BY (\"placed\" DESC)"),
        "{}",
        source.create_statement
    );
    let dependents: Vec<&str> = source
        .dependents
        .iter()
        .map(|dependent| dependent.sql.as_str())
        .collect();
    assert_eq!(
        dependents,
        ["CREATE INDEX \"orders_note\" ON \"tablepro\".\"orders\" (\"note\")"]
    );

    assert!(
        source
            .create_statement
            .contains("\n    AND default_time_to_live = 86400"),
        "{}",
        source.create_statement
    );

    let mut script = vec!["DROP TABLE tablepro.orders", source.create_statement.as_str()];
    script.extend(dependents);
    setup(connection.as_ref(), &script).await;
    let after = connection
        .fetch_columns(&table("orders"), within(CALL))
        .await
        .expect("the rebuilt columns");
    assert_eq!(after, before);
    let ttl = rows(
        connection.as_ref(),
        "SELECT default_time_to_live FROM system_schema.tables \
         WHERE keyspace_name = 'tablepro' AND table_name = 'orders'",
    )
    .await;
    assert_eq!(ttl, [[Value::Int(86_400)]]);
}

/// A role granted only SELECT on one keyspace, which ScyllaDB 2026.1
/// does not let read `system.versions`.
async fn a_role_that_may_only_read_its_keyspace_connects_and_reads<S: Server>() {
    let fixture = start::<S>().await;
    let admin = connect(&fixture, false).await;
    setup(
        admin.as_ref(),
        &[
            "CREATE TABLE tablepro.notes (id int PRIMARY KEY, body text)",
            "INSERT INTO tablepro.notes (id, body) VALUES (1, 'hi')",
        ],
    )
    .await;
    let liveness = test_liveness();
    let connection = connect_with(options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.limited_credentials()),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(true),
        liveness,
    ))
    .await;

    let schemas = connection.list_schemas(within(CALL)).await.expect("the keyspaces");
    let objects = connection
        .list_objects(&ObjectScope::Schema(KEYSPACE.to_owned()), within(CALL))
        .await
        .expect("the tables");

    assert!(schemas.iter().any(|schema| schema.name == KEYSPACE), "{schemas:?}");
    assert!(objects.iter().any(|object| object.name == "notes"), "{objects:?}");
    assert_eq!(
        rows(connection.as_ref(), "SELECT body FROM tablepro.notes").await,
        [[Value::Text("hi".to_owned())]]
    );
    assert_eq!(connection.server_info().product, fixture_product(S::FLAVOUR));
}

fn fixture_product(flavour: CassandraFlavour) -> &'static str {
    match flavour {
        CassandraFlavour::Cassandra => "Cassandra",
        CassandraFlavour::Scylla => "ScyllaDB",
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_role_that_may_only_read_its_keyspace_connects() {
    a_role_that_may_only_read_its_keyspace_connects_and_reads::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_role_that_may_only_read_its_keyspace_connects() {
    a_role_that_may_only_read_its_keyspace_connects_and_reads::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_sidebar_lists_keyspaces_tables_and_views() {
    the_sidebar_lists_keyspaces_tables_and_views::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_sidebar_lists_keyspaces_tables_and_views() {
    the_sidebar_lists_keyspaces_tables_and_views::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_rows_are_keyed_by_the_primary_key() {
    a_table_is_keyed_by_its_primary_key_and_a_view_is_read_only::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_rows_are_keyed_by_the_primary_key() {
    a_table_is_keyed_by_its_primary_key_and_a_view_is_read_only::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_create_script_rebuilds_the_table() {
    the_create_script_rebuilds_the_table_it_was_read_from::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_create_script_rebuilds_the_table() {
    the_create_script_rebuilds_the_table_it_was_read_from::<ScyllaServer>().await;
}
