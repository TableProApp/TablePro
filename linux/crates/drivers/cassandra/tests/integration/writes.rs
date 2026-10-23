//! Editing a row by its key as the grid saves it, and the writes CQL
//! would otherwise turn into an upsert: an update of a row someone
//! deleted, an insert of a key someone took.

use tablepro_core::dml::BuildSqlError;
use tablepro_core::edit::CellInput;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::{Connection, DriverError, TableRef, Value};
use tablepro_test_fixtures::CassandraFixture;

use crate::support::{
    CALL, CassandraServer, ScyllaServer, Server, connect, count, planned, rows, setup, start, within,
};

fn people(keyspace: &str) -> TableRef {
    TableRef::new(Some(keyspace.to_owned()), "people")
}

async fn create_people(connection: &dyn Connection, keyspace: &str) {
    let create = format!("CREATE TABLE {keyspace}.people (team text, id int, name text, PRIMARY KEY (team, id))");
    let first = format!("INSERT INTO {keyspace}.people (team, id, name) VALUES ('a', 1, 'ada')");
    let second = format!("INSERT INTO {keyspace}.people (team, id, name) VALUES ('a', 2, 'grace')");
    setup(connection, &[&create, &first, &second]).await;
}

fn key(team: &str, id: i64) -> Vec<Value> {
    vec![Value::Text(team.to_owned()), Value::Int(id)]
}

fn rename(team: &str, id: i64, name: &str) -> RowChange {
    RowChange::Update(RowUpdate {
        key: key(team, id),
        assignments: vec![(2, Value::Text(name.to_owned()))],
    })
}

fn insert(team: &str, id: i64, name: &str) -> RowChange {
    RowChange::Insert {
        cells: vec![
            CellInput::Value(Value::Text(team.to_owned())),
            CellInput::Value(Value::Int(id)),
            CellInput::Value(Value::Text(name.to_owned())),
        ],
    }
}

async fn save(connection: &dyn Connection, table: &TableRef, changes: Vec<RowChange>) -> Result<(), DriverError> {
    let batch = planned(connection, table, &ChangeSet { changes }).await;
    connection.write_batch(&batch, within(CALL)).await.map(|_| ())
}

async fn names(connection: &dyn Connection, keyspace: &str) -> Vec<(String, i64, Option<String>)> {
    rows(connection, &format!("SELECT team, id, name FROM {keyspace}.people"))
        .await
        .into_iter()
        .map(|row| match row.as_slice() {
            [Value::Text(team), Value::Int(id), Value::Text(name)] => (team.clone(), *id, Some(name.clone())),
            [Value::Text(team), Value::Int(id), Value::Null] => (team.clone(), *id, None),
            other => panic!("a row read as {other:?}"),
        })
        .collect()
}

/// An update, a delete and an insert, each by the full primary key, then
/// each of the writes CQL would quietly turn into another.
async fn rows_are_edited_by_their_key(fixture: &CassandraFixture, keyspace: &str) {
    let connection = connect(fixture, false).await;
    create_people(connection.as_ref(), keyspace).await;
    let table = people(keyspace);

    save(
        connection.as_ref(),
        &table,
        vec![
            rename("a", 1, "ada lovelace"),
            RowChange::Delete { key: key("a", 2) },
            insert("b", 3, "hopper"),
        ],
    )
    .await
    .expect("the save");
    let mut saved = names(connection.as_ref(), keyspace).await;
    saved.sort();
    assert_eq!(
        saved,
        [
            ("a".to_owned(), 1, Some("ada lovelace".to_owned())),
            ("b".to_owned(), 3, Some("hopper".to_owned())),
        ]
    );

    let taken = save(connection.as_ref(), &table, vec![insert("a", 1, "impostor")]).await;
    assert!(
        matches!(taken, Err(DriverError::RowGuardFailed { statement_index: 0, .. })),
        "{taken:?}"
    );
    let gone = save(connection.as_ref(), &table, vec![rename("a", 2, "resurrected")]).await;
    assert!(
        matches!(gone, Err(DriverError::RowGuardFailed { statement_index: 0, .. })),
        "{gone:?}"
    );
    let deleted_twice = save(
        connection.as_ref(),
        &table,
        vec![RowChange::Delete { key: key("a", 2) }],
    )
    .await;
    assert!(
        matches!(
            deleted_twice,
            Err(DriverError::RowGuardFailed { statement_index: 0, .. })
        ),
        "{deleted_twice:?}"
    );
    let mut after = names(connection.as_ref(), keyspace).await;
    after.sort();
    assert_eq!(after, saved, "a refused write changed nothing");
}

async fn rows_are_edited_by_their_key_in_the_fixture_keyspace<S: Server>() {
    let fixture = start::<S>().await;
    rows_are_edited_by_their_key(&fixture, "tablepro").await;
}

/// ScyllaDB 2025.1 refuses a lightweight transaction on a table with
/// tablets, so the save probes for each key instead; 2026.1 takes one.
async fn rows_are_edited_by_their_key_in_a_keyspace_with_tablets() {
    let fixture = start::<ScyllaServer>().await;
    fixture
        .cql(
            "CREATE KEYSPACE tp_tablets WITH replication = \
             {'class': 'NetworkTopologyStrategy', 'replication_factor': 1} AND tablets = {'enabled': true}",
        )
        .await
        .expect("a keyspace with tablets");
    rows_are_edited_by_their_key(&fixture, "tp_tablets").await;
}

/// A static column holds one value for its partition, so an edit of it
/// on one row reaches every row of the partition, set or not before.
async fn a_static_column_is_saved_for_its_partition<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE tablepro.teams (team text, id int, name text, motto text static, PRIMARY KEY (team, id))",
            "INSERT INTO tablepro.teams (team, id, name) VALUES ('a', 1, 'ada')",
            "INSERT INTO tablepro.teams (team, id, name) VALUES ('a', 2, 'grace')",
        ],
    )
    .await;
    let table = TableRef::new(Some("tablepro".to_owned()), "teams");
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
    let motto = columns.iter().position(|column| column.name == "motto").expect("motto");

    save(
        connection.as_ref(),
        &table,
        vec![RowChange::Update(RowUpdate {
            key: key("a", 1),
            assignments: vec![(motto, Value::Text("new".to_owned()))],
        })],
    )
    .await
    .expect("the save");

    let mottos = rows(connection.as_ref(), "SELECT motto FROM tablepro.teams WHERE team = 'a'").await;
    assert_eq!(
        mottos,
        [[Value::Text("new".to_owned())], [Value::Text("new".to_owned())]]
    );
}

/// A counter only moves by an increment, so a counter table's rows have
/// no value a grid edit could set.
async fn a_counter_table_is_read_only<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE tablepro.hits (page text PRIMARY KEY, total counter)",
            "UPDATE tablepro.hits SET total = total + 1 WHERE page = 'home'",
        ],
    )
    .await;
    let table = TableRef::new(Some("tablepro".to_owned()), "hits");

    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("the identity");
    let dialect = connection.dialect();
    let changes = ChangeSet {
        changes: vec![RowChange::Delete {
            key: vec![Value::Text("home".to_owned())],
        }],
    };

    let refused = plan_save(dialect.as_ref(), &table, &columns, &identity, &changes);
    assert_eq!(refused.err(), Some(BuildSqlError::ReadOnlyRows));
    assert_eq!(
        count(connection.as_ref(), "SELECT COUNT(*) FROM tablepro.hits").await,
        1
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_rows_are_edited_by_their_key() {
    rows_are_edited_by_their_key_in_the_fixture_keyspace::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_rows_are_edited_by_their_key() {
    rows_are_edited_by_their_key_in_the_fixture_keyspace::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_rows_are_edited_by_their_key_in_a_keyspace_with_tablets() {
    rows_are_edited_by_their_key_in_a_keyspace_with_tablets().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_static_columns_are_saved_for_their_partition() {
    a_static_column_is_saved_for_its_partition::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_static_columns_are_saved_for_their_partition() {
    a_static_column_is_saved_for_its_partition::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_counter_tables_are_read_only() {
    a_counter_table_is_read_only::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_counter_tables_are_read_only() {
    a_counter_table_is_read_only::<ScyllaServer>().await;
}
