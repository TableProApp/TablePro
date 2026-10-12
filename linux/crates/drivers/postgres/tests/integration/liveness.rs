//! A dead backend is not a dead link, and a dead server is.

use std::time::Duration;

use tablepro_core::{LinkState, RowLimit};

use crate::support::{CALL, connect, run_ok, session, start, statement, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn terminate_backend_link_stays_open_after_healthy_probe() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let killer = session(connection.as_ref()).await;
    let select = statement("SELECT 1");
    connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("a first read");

    run_ok(
        killer.as_ref(),
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
         WHERE application_name = 'TablePro' AND pid <> pg_backend_pid() AND backend_type = 'client backend'",
    )
    .await;
    let first = connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL))
        .await;
    let second = connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL))
        .await;

    assert!(
        second.is_ok(),
        "the pool did not recover: first {first:?}, then {second:?}"
    );
    assert_eq!(connection.link_state(), LinkState::Live);
    assert!(connection.probe(within(CALL)).await.is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn stopped_container_marks_lost() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    connection.probe(within(CALL)).await.expect("a first probe");

    fixture.container().stop().await.expect("the container stopped");
    let probed = connection.probe(within(Duration::from_secs(5))).await;

    assert!(probed.is_err());
    assert_eq!(connection.link_state(), LinkState::Lost);
    assert!(
        tokio::time::timeout(Duration::from_secs(1), connection.lost())
            .await
            .is_ok()
    );
}
