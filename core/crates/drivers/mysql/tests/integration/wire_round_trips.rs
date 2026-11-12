//! How many times a workspace read waits on the server, counted on the
//! wire.

use std::sync::Arc;

use tablepro_core::{TlsConfig, WorkspaceSettings};
use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::RoundTripCounter;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{CALL, connect_with, direct, options_over, password, setup, start, table, within};

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
