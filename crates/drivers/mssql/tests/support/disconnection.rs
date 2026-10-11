#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn a_lost_sql_server_is_reported_as_disconnected() {
    let (container, opts) = start_mssql_durable().await;
    let connection = connect(opts.clone()).await;
    let initial = connection
        .query("SELECT 1")
        .await
        .expect("initial query reaches server");
    assert_eq!(initial.rows, vec![vec![Value::Int(1)]]);

    container.stop().await.expect("stop SQL Server");
    let error = connection
        .query("SELECT 1")
        .await
        .expect_err("query after server loss must fail");
    assert!(
        matches!(error, DriverError::Disconnected),
        "loss of an established SQL Server must be reported as disconnected, got {error:?}"
    );

    container.start().await.expect("restart SQL Server");
    let mut replacement_options = opts;
    replacement_options.host = container.get_host().await.expect("restarted host").to_string();
    replacement_options.port = container
        .get_host_port_ipv4(1433)
        .await
        .expect("restarted SQL Server port");
    let recovered = server_restart::retry_operation("SQL Server", || {
        let options = replacement_options.clone();
        async move {
            let replacement = MssqlDriver.connect(options).await?;
            replacement.query("SELECT 1").await
        }
    })
    .await
    .expect("SQL Server restarts and accepts SELECT 1");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn server_loss_during_multi_result_stream_rejects_the_whole_query() {
    let (container, opts) = start_mssql_durable().await;
    let streaming_connection = connect(opts.clone()).await;
    let admin_connection = connect(opts.clone()).await;
    let sql = "/* tablepro_disconnect_stream_probe */ SELECT CAST(1 AS int) AS n; WAITFOR DELAY '00:00:20'; SELECT CAST(2 AS int) AS n";
    let query = tokio::spawn(async move { streaming_connection.query(sql).await });

    let mut active = false;
    for _ in 0..100 {
        let probe = admin_connection
            .query(
                "SELECT COUNT(*) AS active_count FROM sys.dm_exec_requests r \
                 CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t \
                 WHERE r.session_id <> @@SPID \
                   AND t.text LIKE N'%tablepro_disconnect_stream_probe%'",
            )
            .await
            .expect("inspect SQL Server active requests");
        if probe.rows == vec![vec![Value::Int(1)]] {
            active = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(active, "streaming query must reach WAITFOR before server loss");
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    container.stop().await.expect("stop SQL Server during stream");

    let error = tokio::time::timeout(std::time::Duration::from_secs(20), query)
        .await
        .expect("interrupted stream must finish promptly")
        .expect("query task must not panic")
        .expect_err("interrupted multi-result query must fail without returning partial rows");
    assert!(
        matches!(error, DriverError::Disconnected),
        "mid-stream SQL Server loss must be Disconnected, got {error:?}"
    );

    container.start().await.expect("restart SQL Server");
    let mut replacement_options = opts;
    replacement_options.host = container.get_host().await.expect("restarted host").to_string();
    replacement_options.port = container
        .get_host_port_ipv4(1433)
        .await
        .expect("restarted SQL Server port");
    let recovered = server_restart::retry_operation("SQL Server", || {
        let options = replacement_options.clone();
        async move {
            let replacement = MssqlDriver.connect(options).await?;
            replacement.query("SELECT 1").await
        }
    })
    .await
    .expect("SQL Server restarts and accepts SELECT 1");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_committed_update_with_a_lost_ack_is_not_replayed() {
    let (container, opts) = start_mssql_durable().await;
    let observer = connect(opts.clone()).await;
    observer
        .execute("CREATE TABLE lost_ack_target (id INT PRIMARY KEY, value INT NOT NULL)")
        .await
        .expect("create target table");
    observer
        .execute("CREATE TABLE lost_ack_audit (target_id INT NOT NULL)")
        .await
        .expect("create independent audit table");
    observer
        .execute("INSERT INTO lost_ack_target VALUES (1, 0)")
        .await
        .expect("seed target row");

    let connection = connect(opts.clone()).await;
    let sql = "UPDATE lost_ack_target SET value = value + 1 OUTPUT inserted.id INTO lost_ack_audit(target_id) WHERE id = 1; WAITFOR DELAY '00:00:20'";
    let query = tokio::spawn(async move { connection.execute(sql).await });
    let mut committed = false;
    for _ in 0..100 {
        let target = observer
            .query("SELECT value FROM lost_ack_target WHERE id = 1")
            .await
            .expect("observe committed target row");
        let audit = observer
            .query("SELECT target_id FROM lost_ack_audit ORDER BY target_id")
            .await
            .expect("observe independent audit row");
        if target.rows == vec![vec![Value::Int(1)]] && audit.rows == vec![vec![Value::Int(1)]] {
            committed = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(
        committed,
        "target and audit rows must commit before the delayed batch response"
    );
    assert!(
        !query.is_finished(),
        "the SQL Server batch must still be waiting when its committed acknowledgement is cut"
    );
    container
        .stop_with_timeout(Some(0))
        .await
        .expect("forcibly stop SQL Server after the update commits");
    let error = tokio::time::timeout(std::time::Duration::from_secs(20), query)
        .await
        .expect("lost SQL Server acknowledgement must not hang")
        .expect("query task")
        .expect_err("server loss before the batch response must leave the write uncertain");
    assert!(
        matches!(error, DriverError::Disconnected),
        "a committed SQL Server UPDATE with a lost response must remain uncertain, got {error:?}"
    );

    container.start().await.expect("restart SQL Server");
    let mut replacement_options = opts;
    replacement_options.host = container.get_host().await.expect("restarted host").to_string();
    replacement_options.port = container
        .get_host_port_ipv4(1433)
        .await
        .expect("restarted SQL Server port");
    let (target, audit) = server_restart::retry_operation("SQL Server", || {
        let options = replacement_options.clone();
        async move {
            let connection = MssqlDriver.connect(options).await?;
            let target = connection
                .query("SELECT value FROM lost_ack_target WHERE id = 1")
                .await?;
            let audit = connection
                .query("SELECT target_id FROM lost_ack_audit ORDER BY target_id")
                .await?;
            Ok((target, audit))
        }
    })
    .await
    .expect("restarted SQL Server reads committed target and audit rows");
    assert_eq!(target.rows, vec![vec![Value::Int(1)]]);
    assert_eq!(audit.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_disconnected_session_is_retired_after_server_loss() {
    let (container, opts) = start_mssql_durable().await;
    let connection = connect(opts.clone()).await;
    let observer = connect(opts).await;
    let mut session = connection.open_session().await.expect("open session");
    let tag = "tablepro_session_disconnect_probe";
    let query = tokio::spawn(async move {
        let result = session
            .query_params_controlled(
                &format!("/* {tag} */ WAITFOR DELAY '00:00:30'"),
                &[],
                &OperationControl::with_timeout(std::time::Duration::from_secs(40)),
            )
            .await;
        (session, result)
    });

    let mut active = false;
    for _ in 0..100 {
        let probe = observer
            .query(&format!(
                "SELECT COUNT(*) AS active_count FROM sys.dm_exec_requests r \
                 CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t \
                 WHERE r.session_id <> @@SPID AND t.text LIKE N'%{tag}%'"
            ))
            .await
            .expect("inspect active SQL Server session query");
        if probe.rows == vec![vec![Value::Int(1)]] {
            active = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(active, "session query must reach WAITFOR before server loss");
    container.stop().await.expect("stop SQL Server during session query");

    let (session, result) = tokio::time::timeout(std::time::Duration::from_secs(20), query)
        .await
        .expect("disconnected session query must finish promptly")
        .expect("session query task");
    let error = result.expect_err("server loss must fail the session query");
    assert!(matches!(error, DriverError::Disconnected), "{error:?}");
    assert!(!session.is_usable(), "a disconnected session must be retired");
}

#[path = "disconnection_parts/database_listing.rs"]
mod database_listing;
