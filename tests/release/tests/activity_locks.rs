#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{ActivityQuery, Connection, Value, activity_sql};
use tablepro_release_tests::Fixture;

async fn activity_rows(connection: &dyn Connection, kind: ActivityQuery) -> usize {
    let sql = activity_sql("postgres", kind, None).expect("postgres activity template");
    let result = connection.query(&sql).await.expect("activity query");
    if kind == ActivityQuery::Sessions {
        let duration = result
            .columns
            .iter()
            .position(|column| column.name == "duration")
            .expect("duration column");
        assert!(
            result
                .rows
                .iter()
                .any(|row| matches!(row.get(duration), Some(Value::Text(_)))),
            "activity must return a readable duration rather than silently decoding it as NULL"
        );
    }
    result.rows.len()
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn activity_templates_run_against_a_verified_session() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;

    assert!(activity_rows(connection.as_ref(), ActivityQuery::Sessions).await >= 1);
    activity_rows(connection.as_ref(), ActivityQuery::LongRunning).await;
    activity_rows(connection.as_ref(), ActivityQuery::BlockingLocks).await;
    activity_rows(connection.as_ref(), ActivityQuery::ReplicationLag).await;
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn blocking_lock_query_reports_a_contended_row() {
    let fixture = Fixture::from_env();
    let holder = fixture.connect_verified().await;
    let waiter = fixture.connect_verified().await;
    let observer = fixture.connect_verified().await;

    let mut transaction = holder.begin().await.expect("begin the blocking transaction");
    transaction
        .execute("UPDATE lock_targets SET note = 'held' WHERE id = 1")
        .await
        .expect("take the row lock");

    let waiting = tokio::spawn(async move {
        waiter
            .execute("UPDATE lock_targets SET note = 'waiting' WHERE id = 1")
            .await
    });

    let mut blocked = 0;
    for _ in 0..100 {
        let sql = activity_sql("postgres", ActivityQuery::BlockingLocks, None).expect("blocking lock template");
        blocked = observer.query(&sql).await.expect("blocking lock query").rows.len();
        if blocked > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(blocked > 0, "the blocking lock query must report the contended row");

    transaction.rollback().await.expect("release the row lock");
    waiting
        .await
        .expect("waiting task")
        .expect("the waiting update completes");

    let result = observer
        .query("SELECT note FROM lock_targets WHERE id = 1")
        .await
        .expect("read the contended row");
    assert_eq!(
        result.rows.first().and_then(|row| row.first()),
        Some(&Value::Text("waiting".into()))
    );
}
