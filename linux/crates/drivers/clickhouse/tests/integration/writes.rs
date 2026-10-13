//! Saves on an engine whose writes are neither atomic nor stoppable, and
//! what the query log says about one whose answer never arrived.

use std::time::Duration;

use tablepro_core::save::{ChangeSet, RowUpdate};
use tablepro_core::{
    CommitResolution, CommitToken, Connection, DriverError, ReadOnlyRefusal, RunEnd, ServerCode, StatementOutcome,
    Value, WriteKind,
};
use tokio::time::Instant;

use crate::support::{
    CALL, DATABASE, admin, apply, batch_on, connect, count, flush_logs, planned, quoted, run, scalar, session, setup,
    start, table, text, unique, within,
};

/// A mutation that takes seconds on a small table, so it cannot finish
/// inside a short deadline yet does not fill the disk.
fn slow_update(qualified: &str) -> String {
    format!(
        "ALTER TABLE {qualified} UPDATE s = toString(arraySum(arrayMap(x -> cityHash64(x, n), range(1500)))) WHERE 1"
    )
}

async fn slow_table(connection: &dyn Connection, name: &str) -> String {
    let qualified = quoted(name);
    setup(
        connection,
        &[&format!(
            "CREATE TABLE {qualified} ENGINE = MergeTree ORDER BY n \
             AS SELECT number AS n, toString(number) AS s FROM numbers(1000000)"
        )],
    )
    .await;
    qualified
}

async fn resolution(connection: &dyn Connection, token: &CommitToken) -> CommitResolution {
    connection
        .resolve_commit(token, within(CALL))
        .await
        .expect("a resolution")
}

async fn logged_query_id(connection: &dyn Connection, filter: &str) -> uuid::Uuid {
    flush_logs(connection).await;
    let id = scalar(
        connection,
        &format!("SELECT query_id FROM system.query_log WHERE event_date >= today() - 1 AND {filter} LIMIT 1"),
    )
    .await;
    text(&id).parse().expect("a query id")
}

#[tokio::test]
#[ignore = "requires docker"]
async fn duplicate_sorting_key_edit_sends_no_mutation_row_guard_failed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("duplicates");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32, v String) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1, 'a'), (1, 'b')"),
        ],
    )
    .await;
    let mutations = format!("SELECT count() FROM system.mutations WHERE database = '{DATABASE}' AND table = '{name}'");
    let before = count(connection.as_ref(), &mutations).await;

    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Int(1)],
            assignments: vec![(1, Value::Text("x".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    let batch = planned(connection.as_ref(), &table(&name), &changes).await;
    let outcome = connection.write_batch(&batch, within(CALL)).await;

    assert_eq!(
        outcome,
        Err(DriverError::RowGuardFailed {
            statement_index: 0,
            expected: 1,
            actual: 2
        })
    );
    assert_eq!(
        count(connection.as_ref(), &mutations).await,
        before,
        "a mutation was sent"
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn three_inserts_second_fails_partially_applied_applied_1() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let qualified = quoted(&unique("partial"));
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"
        )],
    )
    .await;

    let outcome = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &[
            &format!("INSERT INTO {qualified} VALUES (1)"),
            &format!("INSERT INTO {qualified} (id, missing) VALUES (2, 0)"),
            &format!("INSERT INTO {qualified} VALUES (3)"),
        ],
    )
    .await;

    assert!(
        matches!(
            outcome,
            Err(DriverError::PartiallyApplied {
                applied: 1,
                statement_index: 1,
                failed_outcome: StatementOutcome::Failed,
                ..
            })
        ),
        "{outcome:?}"
    );
    assert_eq!(
        count(connection.as_ref(), &format!("SELECT count() FROM {qualified}")).await,
        1
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn write_statements_never_carry_max_execution_time() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("unbounded");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32, v String) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1, 'a')"),
        ],
    )
    .await;
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Int(1)],
            assignments: vec![(1, Value::Text("b".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    let batch = planned(connection.as_ref(), &table(&name), &changes).await;
    connection.write_batch(&batch, within(CALL)).await.expect("the edit");

    flush_logs(connection.as_ref()).await;
    let bounded = count(
        connection.as_ref(),
        &format!(
            "SELECT count() FROM system.query_log WHERE query_kind = 'Alter' \
             AND has(tables, '{DATABASE}.{name}') AND toUInt64OrZero(Settings['max_execution_time']) > 0"
        ),
    )
    .await;
    let altered = count(
        connection.as_ref(),
        &format!(
            "SELECT count() FROM system.query_log WHERE query_kind = 'Alter' \
             AND type = 'QueryFinish' AND has(tables, '{DATABASE}.{name}')"
        ),
    )
    .await;
    let killed = count(
        connection.as_ref(),
        "SELECT count() FROM system.query_log WHERE query ILIKE 'KILL QUERY%'",
    )
    .await;
    assert_eq!((altered, bounded, killed), (1, 0, 0));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn alter_update_deadline_commit_outcome_unknown_resolves_still_running_then_applied() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("deadline");
    let qualified = slow_table(connection.as_ref(), &name).await;

    let outcome = connection
        .write_batch(
            &batch_on(&name, &[&slow_update(&qualified)]),
            within(Duration::from_secs(1)),
        )
        .await;

    let Err(DriverError::CommitOutcomeUnknown { token: Some(token), .. }) = outcome else {
        panic!("a mutation past its deadline gave {outcome:?}");
    };
    assert_eq!(
        resolution(connection.as_ref(), &token).await,
        CommitResolution::StillRunning
    );
    let give_up = Instant::now() + Duration::from_secs(120);
    loop {
        match resolution(connection.as_ref(), &token).await {
            CommitResolution::Applied => break,
            CommitResolution::StillRunning if Instant::now() < give_up => {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            other => panic!("the mutation resolved as {other:?}"),
        }
    }
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn alter_update_killed_by_other_session_is_unknown_not_cancelled() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("killed");
    let qualified = slow_table(connection.as_ref(), &name).await;

    let writing = {
        let connection = connection.clone();
        let update = batch_on(&name, &[&slow_update(&qualified)]);
        tokio::spawn(async move { connection.write_batch(&update, within(CALL)).await })
    };
    let monitor = session(connection.as_ref()).await;
    let find = format!(
        "SELECT query_id FROM system.processes WHERE query LIKE 'ALTER TABLE%{name}%' \
         AND query NOT LIKE '%system.processes%'"
    );
    let give_up = Instant::now() + Duration::from_secs(10);
    let query_id = loop {
        let (_, events) = run(monitor.as_ref(), &find).await;
        if let Some(row) = events.rows().into_iter().next() {
            break text(&row[0]);
        }
        assert!(
            Instant::now() < give_up,
            "the ALTER never showed up in system.processes"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    admin(
        connection.as_ref(),
        &format!("KILL QUERY WHERE query_id = '{query_id}' SYNC"),
    )
    .await;

    let outcome = writing.await.expect("the write task");
    let Err(DriverError::CommitOutcomeUnknown { token: Some(token), .. }) = outcome else {
        panic!("a killed mutation wait gave {outcome:?}");
    };
    let resolved = resolution(connection.as_ref(), &token).await;
    assert!(
        matches!(resolved, CommitResolution::StillRunning | CommitResolution::Applied),
        "the killed ALTER's mutation was not found: {resolved:?}"
    );
    monitor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn failing_mutation_unfinished_is_unknown_and_still_running() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("failing");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32, n UInt8, s String) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1, 0, 'abc')"),
        ],
    )
    .await;

    let outcome = connection
        .write_batch(
            &batch_on(
                &name,
                &[&format!("ALTER TABLE {qualified} UPDATE n = toUInt8(s) WHERE 1")],
            ),
            within(CALL),
        )
        .await;

    let Err(DriverError::CommitOutcomeUnknown { token: Some(token), .. }) = outcome else {
        panic!("a failing mutation gave {outcome:?}");
    };
    assert_eq!(
        resolution(connection.as_ref(), &token).await,
        CommitResolution::StillRunning
    );
    admin(
        connection.as_ref(),
        &format!("KILL MUTATION WHERE database = '{DATABASE}' AND table = '{name}' SYNC"),
    )
    .await;
    connection.close().await.expect("a close");
}

/// The ALTER's mutation never runs and is killed, while another table's
/// mutation lands inside the ALTER's window. Its log names no table, so
/// only the table the write was for can keep the other one out.
#[tokio::test]
#[ignore = "requires docker"]
async fn killed_mutation_unresolvable_despite_another_tables_mutation_in_its_window() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let held = unique("held");
    let other = unique("other");
    let (held_table, other_table) = (quoted(&held), quoted(&other));
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {held_table} (id Int32, n Int32) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {held_table} VALUES (1, 0)"),
            &format!("CREATE TABLE {other_table} (id Int32, n Int32) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {other_table} VALUES (1, 0)"),
        ],
    )
    .await;
    admin(connection.as_ref(), &format!("SYSTEM STOP MERGES {held_table}")).await;

    let writing = {
        let connection = connection.clone();
        let update = batch_on(&held, &[&format!("ALTER TABLE {held_table} UPDATE n = 1 WHERE 1")]);
        tokio::spawn(async move { connection.write_batch(&update, within(CALL)).await })
    };
    let waiting = format!(
        "SELECT count() FROM system.processes WHERE query LIKE 'ALTER TABLE%{held}%' \
         AND query NOT LIKE '%system.processes%'"
    );
    let give_up = Instant::now() + Duration::from_secs(10);
    while count(connection.as_ref(), &waiting).await == 0 {
        assert!(
            Instant::now() < give_up,
            "the ALTER never showed up in system.processes"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    admin(
        connection.as_ref(),
        &format!("ALTER TABLE {other_table} UPDATE n = 1 WHERE 1"),
    )
    .await;
    admin(
        connection.as_ref(),
        &format!("KILL MUTATION WHERE database = '{DATABASE}' AND table = '{held}' SYNC"),
    )
    .await;

    let outcome = writing.await.expect("the write task");
    let Err(DriverError::CommitOutcomeUnknown { token: Some(token), .. }) = outcome else {
        panic!("a mutation killed under its ALTER gave {outcome:?}");
    };
    assert_eq!(
        count(
            connection.as_ref(),
            &format!("SELECT count() FROM system.mutations WHERE table = '{other}' AND is_done")
        )
        .await,
        1,
        "the other table's mutation did not land"
    );
    assert_eq!(
        resolution(connection.as_ref(), &token).await,
        CommitResolution::Unresolvable
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn resolve_finished_insert_applied() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("finished");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1)"),
        ],
    )
    .await;
    let query_id = logged_query_id(
        connection.as_ref(),
        &format!("type = 'QueryFinish' AND query_kind = 'Insert' AND has(tables, '{DATABASE}.{name}')"),
    )
    .await;

    let token = CommitToken::ClickHouseQuery {
        query_ids: vec![query_id],
        first_unconfirmed: 0,
        table: table(&name),
    };

    assert_eq!(resolution(connection.as_ref(), &token).await, CommitResolution::Applied);
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn resolve_random_id_unresolvable() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let token = CommitToken::ClickHouseQuery {
        query_ids: vec![uuid::Uuid::new_v4()],
        first_unconfirmed: 0,
        table: table("t"),
    };

    assert_eq!(
        resolution(connection.as_ref(), &token).await,
        CommitResolution::Unresolvable
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn resolve_syntax_error_insert_not_applied() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("syntax");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"
        )],
    )
    .await;

    let refused = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &[&format!("INSERT INTO {qualified} (id SELECT 1")],
    )
    .await;
    assert!(
        matches!(refused, Err(DriverError::RolledBack { statement_index: 0, .. })),
        "{refused:?}"
    );
    let query_id = logged_query_id(
        connection.as_ref(),
        &format!("type = 'ExceptionBeforeStart' AND exception_code = 62 AND query LIKE '%{name}%'"),
    )
    .await;
    let token = CommitToken::ClickHouseQuery {
        query_ids: vec![query_id],
        first_unconfirmed: 0,
        table: table(&name),
    };

    assert_eq!(
        resolution(connection.as_ref(), &token).await,
        CommitResolution::NotApplied
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn read_only_insert_164() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    let qualified = quoted(&unique("read_only"));
    setup(
        owner.as_ref(),
        &[&format!(
            "CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"
        )],
    )
    .await;
    let reader = connect(&fixture, true).await;

    let editor = session(reader.as_ref()).await;
    let (summary, _) = run(editor.as_ref(), &format!("INSERT INTO {qualified} VALUES (1)")).await;
    let saved = apply(
        reader.as_ref(),
        WriteKind::RowChanges,
        &[&format!("INSERT INTO {qualified} VALUES (2)")],
    )
    .await;

    let RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics))) = &summary.end else {
        panic!("an INSERT on a read-only session ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.code, Some(ServerCode::ClickHouse { code: 164 }));
    assert_eq!(saved, Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)));
    assert_eq!(
        count(owner.as_ref(), &format!("SELECT count() FROM {qualified}")).await,
        0
    );
    editor.close().await;
    reader.close().await.expect("a close");
    owner.close().await.expect("a close");
}
