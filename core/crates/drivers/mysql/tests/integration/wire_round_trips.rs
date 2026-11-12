//! How many times a workspace read waits on the server, counted on the
//! wire.

use std::sync::Arc;

use tablepro_core::{RowLimit, TlsConfig, WorkspaceSettings};
use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::RoundTripCounter;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{CALL, connect_with, direct, options_over, password, setup, start, statement, table, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_catalog_read_on_a_warm_connection_costs_one_round_trip() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let liveness = test_liveness();
    let counter = Arc::new(RoundTripCounter::new(direct(fixture.host(), fixture.port(), &liveness)));
    let connection = connect_with(options_over(
        counter.clone(),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE t (id int PRIMARY KEY, name varchar(20))"],
    )
    .await;
    let columns = || async {
        let before = counter.round_trips();
        connection
            .fetch_columns(&table("t"), within(CALL))
            .await
            .expect("the columns");
        counter.round_trips() - before
    };
    columns().await;

    // The pool's ping before the read is the other round trip.
    assert_eq!([columns().await, columns().await], [2, 2]);
    connection.close().await.expect("a close");
}

/// The columns of an empty page come from a prepare, which must not
/// serve the columns the same text had before a schema change.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_empty_page_shows_the_columns_after_a_type_change() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = crate::support::connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE e (id int PRIMARY KEY, n int)"]).await;
    let columns = || async {
        connection
            .query_bound(&statement("SELECT * FROM e"), RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .expect("an empty page")
            .columns
            .iter()
            .map(|column| column.column_type.name.clone())
            .collect::<Vec<_>>()
    };
    let before = columns().await;

    setup(connection.as_ref(), &["ALTER TABLE e MODIFY n varchar(20)"]).await;

    assert_ne!(
        columns().await,
        before,
        "the empty page kept the columns from before the change"
    );
    connection.close().await.expect("a close");
}
