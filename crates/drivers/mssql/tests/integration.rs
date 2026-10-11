#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[path = "../../shared/server_restart.rs"]
mod server_restart;

use std::str::FromStr;

use chrono::{NaiveDate, NaiveTime};
use rust_decimal::Decimal;

use drivers_mssql::MssqlDriver;
use shared_container::{assert_tmpfs_data_dir, start_mssql, start_mssql_durable};
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, OperationControl, Value};

#[path = "../../shared/connect_refusal.rs"]
mod connect_refusal;
#[path = "support/datetimeoffset_csv.rs"]
mod datetimeoffset_csv;
#[path = "support/disconnection.rs"]
mod disconnection;
#[path = "support/result_sets.rs"]
mod result_sets;
#[path = "support/server_owned_columns.rs"]
mod server_owned_columns;
#[path = "support/shared_container.rs"]
mod shared_container;
#[path = "support/sql_variant.rs"]
mod sql_variant;
#[path = "support/temporal_boundaries.rs"]
mod temporal_boundaries;

#[tokio::test]
async fn an_unavailable_sql_server_is_classified_as_connection_refused() {
    connect_refusal::assert_connection_refused(&MssqlDriver)
        .await
        .expect("SQL Server setup refusal remains distinct from established disconnect");
}

async fn connect(opts: ConnectOptions) -> Box<dyn Connection> {
    MssqlDriver.connect(opts).await.expect("connect")
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_pk_and_identity() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE pk_demo (
            id int IDENTITY(1,1) PRIMARY KEY,
            name nvarchar(255) NOT NULL,
            note nvarchar(max) NULL
        )",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO pk_demo (name, note) VALUES (N'a', NULL), (N'b', N'second')")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "pk_demo"));

    let cols = conn.fetch_columns(None, "pk_demo").await.unwrap();
    assert_eq!(cols.len(), 3);
    let id_col = cols.iter().find(|c| c.name == "id").unwrap();
    assert!(id_col.primary_key, "id must be detected as primary key");
    assert!(id_col.is_auto_increment, "IDENTITY must flag auto-increment");
    assert!(!id_col.nullable);
    let note_col = cols.iter().find(|c| c.name == "note").unwrap();
    assert!(!note_col.primary_key);
    assert!(note_col.nullable);

    let result = conn.fetch_rows(None, "pk_demo", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_roundtrip_representative_types() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE types_demo (
            b bit,
            i int,
            big bigint,
            f float,
            dec decimal(18,4),
            s nvarchar(100),
            bin varbinary(16),
            d date,
            t time,
            dt2 datetime2,
            uid uniqueidentifier
        )",
    )
    .await
    .unwrap();

    let uid = uuid::Uuid::from_u128(0x1234_5678_9abc_def0_1122_3344_5566_7788);
    let dec = Decimal::from_str("1234.5678").unwrap();
    let date = NaiveDate::from_ymd_opt(2024, 1, 15).unwrap();
    let time = NaiveTime::from_hms_opt(10, 30, 0).unwrap();
    let dt2 = date.and_hms_opt(10, 30, 0).unwrap();
    let params = vec![
        Value::Bool(true),
        Value::Int(42),
        Value::Int(9_000_000_000),
        Value::Float(2.5),
        Value::Decimal(dec),
        Value::Text("héllo".into()),
        Value::Bytes(vec![1, 2, 3, 4]),
        Value::Date(date),
        Value::Time(time),
        Value::DateTime(dt2),
        Value::Uuid(uid),
    ];
    conn.execute_params(
        "INSERT INTO types_demo (b, i, big, f, dec, s, bin, d, t, dt2, uid) \
         VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7, @P8, @P9, @P10, @P11)",
        &params,
    )
    .await
    .unwrap();

    let result = conn
        .query("SELECT b, i, big, f, dec, s, bin, d, t, dt2, uid FROM types_demo")
        .await
        .unwrap();
    assert_eq!(result.rows.len(), 1);
    let row = &result.rows[0];
    assert_eq!(row[0], Value::Bool(true));
    assert_eq!(row[1], Value::Int(42));
    assert_eq!(row[2], Value::Int(9_000_000_000));
    assert_eq!(row[3], Value::Float(2.5));
    assert_eq!(row[4], Value::Decimal(dec));
    assert_eq!(row[5], Value::Text("héllo".into()));
    assert_eq!(row[6], Value::Bytes(vec![1, 2, 3, 4]));
    assert_eq!(row[7], Value::Date(date));
    assert_eq!(row[8], Value::Time(time));
    assert_eq!(row[9], Value::DateTime(dt2));
    assert_eq!(row[10], Value::Uuid(uid));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pagination_and_truncated_flag() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE big (i int PRIMARY KEY)").await.unwrap();
    let mut sql = String::from("INSERT INTO big (i) VALUES ");
    for i in 0..50 {
        if i > 0 {
            sql.push(',');
        }
        sql.push_str(&format!("({i})"));
    }
    conn.execute(&sql).await.unwrap();

    // fetch_rows pages with OFFSET/FETCH; order is not guaranteed, so assert
    // the page size only.
    let page = conn.fetch_rows(None, "big", 10, 5).await.unwrap();
    assert_eq!(page.rows.len(), 5);
    assert!(!page.truncated);

    // Ordered query for deterministic value assertions.
    let q = conn
        .query("SELECT i FROM big ORDER BY i OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY")
        .await
        .unwrap();
    let firsts: Vec<i64> = q
        .rows
        .iter()
        .map(|r| match r[0] {
            Value::Int(i) => i,
            _ => panic!("expected int"),
        })
        .collect();
    assert_eq!(firsts, vec![10, 11, 12, 13, 14]);

    let all = conn.query("SELECT i FROM big ORDER BY i").await.unwrap();
    assert_eq!(all.rows.len(), 50);
    assert!(!all.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    let err = conn.query("SELECT * FROM no_such_table").await.unwrap_err();
    let msg = format!("{err}").to_lowercase();
    assert!(
        msg.contains("no_such_table") || msg.contains("invalid object") || msg.contains("object name"),
        "expected error to mention the missing object, got: {msg}"
    );
}

/// The structure editor's Save path. Transaction control has to travel
/// as a SQL batch: tiberius routes `query` / `execute` through
/// `sp_executesql`, and SQL Server rejects a stored procedure that
/// returns with a different `@@TRANCOUNT` than it entered with (Msg
/// 266), leaving the transaction open on the connection.
#[tokio::test]
#[ignore = "requires docker"]
async fn ddl_batch_commits_and_rolls_back_as_a_unit() {
    let (container, opts) = start_mssql().await;
    assert_tmpfs_data_dir(&container).await;
    let conn = connect(opts).await;

    let committed = conn
        .execute_in_transaction(&[
            ("CREATE TABLE tx_demo (id int NOT NULL)".to_string(), Vec::new()),
            ("ALTER TABLE tx_demo ADD name nvarchar(50) NULL".to_string(), Vec::new()),
        ])
        .await
        .unwrap();
    assert_eq!(committed.len(), 2);
    assert_eq!(conn.fetch_columns(None, "tx_demo").await.unwrap().len(), 2);

    let err = conn
        .execute_in_transaction(&[
            ("ALTER TABLE tx_demo ADD extra int NULL".to_string(), Vec::new()),
            ("ALTER TABLE tx_demo ADD extra int NULL".to_string(), Vec::new()),
        ])
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        tablepro_core::DriverError::Transaction { statement_index: 1, .. }
    ));
    let cols = conn.fetch_columns(None, "tx_demo").await.unwrap();
    assert_eq!(cols.len(), 2, "the failed batch must roll back the first statement");
    assert!(!cols.iter().any(|c| c.name == "extra"));

    // The connection is still usable, which it would not be if a
    // half-open transaction were left behind holding schema locks.
    conn.execute("CREATE TABLE tx_demo_after (id int)").await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn alter_column_keeps_its_collation() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE collation_demo (id int PRIMARY KEY, label nvarchar(40) COLLATE Latin1_General_100_BIN2 NULL)",
    )
    .await
    .unwrap();
    let mut column = tablepro_core::sql_ddl::DraftColumn::from_info(
        conn.fetch_columns(None, "collation_demo")
            .await
            .unwrap()
            .into_iter()
            .find(|column| column.name == "label")
            .unwrap(),
    );
    assert_eq!(column.collation.as_deref(), Some("Latin1_General_100_BIN2"));
    column.nullable = false;
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "collation_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let altered = conn.fetch_columns(None, "collation_demo").await.unwrap();
    let label = altered.iter().find(|column| column.name == "label").unwrap();
    assert!(!label.nullable);
    assert_eq!(label.collation.as_deref(), Some("Latin1_General_100_BIN2"));
}

/// Default constraints are separate objects here, so a default change
/// is drop-then-add against a server-generated constraint name.
#[tokio::test]
#[ignore = "requires docker"]
async fn alter_column_default_round_trips() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE def_demo (id int NOT NULL, status nvarchar(20) NULL)")
        .await
        .unwrap();

    let mut column = tablepro_core::sql_ddl::DraftColumn {
        original: Some(
            conn.fetch_columns(None, "def_demo")
                .await
                .unwrap()
                .into_iter()
                .find(|c| c.name == "status")
                .unwrap(),
        ),
        name: "status".into(),
        data_type: "nvarchar(20)".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: Some("'pending'".into()),
        comment: None,
        collation: None,
    };
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "def_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let status = |cols: Vec<tablepro_core::ColumnInfo>| cols.into_iter().find(|c| c.name == "status").unwrap();
    let after_add = status(conn.fetch_columns(None, "def_demo").await.unwrap());
    assert_eq!(after_add.default_value.as_deref(), Some("'pending'"));

    conn.execute("INSERT INTO def_demo (id) VALUES (1)").await.unwrap();
    let rows = conn.query("SELECT status FROM def_demo").await.unwrap();
    assert_eq!(rows.rows[0][0], Value::Text("pending".into()));

    column.original = Some(after_add);
    column.default_value = None;
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "def_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    assert!(
        status(conn.fetch_columns(None, "def_demo").await.unwrap())
            .default_value
            .is_none()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn foreign_key_actions_round_trip() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE fk_parent (id int NOT NULL PRIMARY KEY)")
        .await
        .unwrap();
    conn.execute("CREATE TABLE fk_child (id int NOT NULL PRIMARY KEY, parent_id int NULL)")
        .await
        .unwrap();

    let fk = tablepro_core::ForeignKeyInfo {
        name: "fk_child_parent".into(),
        columns: vec!["parent_id".into()],
        ref_schema: None,
        ref_table: "fk_parent".into(),
        ref_columns: vec!["id".into()],
        on_delete: Some("CASCADE".into()),
        on_update: Some("NO ACTION".into()),
    };
    let sql = tablepro_core::sql_ddl::build_add_foreign_key("mssql", None, "fk_child", &fk).unwrap();
    conn.execute(&sql).await.unwrap();

    let fks = conn.fetch_foreign_keys(None, "fk_child").await.unwrap();
    assert_eq!(fks.len(), 1);
    assert_eq!(fks[0].columns, vec!["parent_id".to_string()]);
    assert_eq!(fks[0].ref_table, "fk_parent");
    assert_eq!(fks[0].on_delete.as_deref(), Some("CASCADE"));

    // RESTRICT is not in the T-SQL grammar, so the builder refuses it
    // rather than handing the server a syntax error.
    let mut restricted = fk.clone();
    restricted.name = "fk_restrict".into();
    restricted.on_delete = Some("RESTRICT".into());
    assert!(tablepro_core::sql_ddl::build_add_foreign_key("mssql", None, "fk_child", &restricted).is_err());
}

/// An index's INCLUDE columns are not part of its key and carry
/// key_ordinal 0, so leaving them in the catalog query would both list
/// them as key columns and sort them ahead of the real ones.
#[tokio::test]
#[ignore = "requires docker"]
async fn index_columns_exclude_included_columns() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE ix_demo (a int NOT NULL, b int NOT NULL, c int NULL, d int NULL)")
        .await
        .unwrap();
    conn.execute("CREATE INDEX ix_demo_ab ON ix_demo (a, b) INCLUDE (c, d)")
        .await
        .unwrap();

    let indexes = conn.fetch_indexes(None, "ix_demo").await.unwrap();
    let ix = indexes.iter().find(|i| i.name == "ix_demo_ab").unwrap();
    assert_eq!(ix.columns, vec!["a".to_string(), "b".to_string()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn empty_result_set_still_reports_columns() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE empty_demo (id int NOT NULL, label nvarchar(10) NULL)")
        .await
        .unwrap();

    let result = conn.query("SELECT id, label FROM empty_demo").await.unwrap();
    assert!(result.rows.is_empty());
    let names: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "label"]);

    let paged = conn.fetch_rows(None, "empty_demo", 0, 50).await.unwrap();
    assert!(paged.rows.is_empty());
    assert_eq!(paged.columns.len(), 2);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_result_cut_at_the_row_limit_still_finishes_the_batch() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    let over_limit = tablepro_core::MAX_QUERY_ROWS + 5;
    let sql = format!(
        "SELECT TOP ({over_limit}) 1 AS one FROM sys.all_columns a CROSS JOIN sys.all_columns b; SELECT 1/0 AS c"
    );
    let err = conn.query(&sql).await.unwrap_err();
    assert!(format!("{err}").to_lowercase().contains("divide by zero"), "got: {err}");

    let result = conn.query("SELECT 7 AS n").await.unwrap();
    assert_eq!(result.rows, vec![vec![Value::Int(7)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_driver_does_not_claim_server_side_cancellation() {
    let (_c, opts) = start_mssql().await;
    let connection = connect(opts).await;
    assert!(
        !connection.supports_server_cancellation(),
        "tiberius cannot send the TDS attention packet, so a Stop must not be offered"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_interrupted_statement_retires_the_connection_instead_of_stranding_it() {
    let (_c, opts) = start_mssql().await;
    let connection: std::sync::Arc<dyn Connection> = MssqlDriver.connect(opts).await.expect("connect").into();

    let token = tokio_util::sync::CancellationToken::new();
    let control = tablepro_core::OperationControl::new(token.clone(), None);
    let running = connection.clone();
    let task = tokio::spawn(async move {
        running
            .query_controlled(
                "WAITFOR DELAY '00:00:30'; SELECT 1 /* tablepro_mssql_retire */",
                &control,
            )
            .await
    });
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    token.cancel();

    let error = task
        .await
        .expect("query task")
        .expect_err("an interrupted query must not succeed");
    assert!(
        matches!(error, tablepro_core::DriverError::OperationOutcomeUnknown { .. }),
        "the statement may still be running, so the outcome must be unknown: {error:?}"
    );

    // The regression: this used to block forever on the poisoned client.
    let reused = tokio::time::timeout(std::time::Duration::from_secs(5), connection.query("SELECT 1")).await;
    let reused = reused.expect("a retired connection must answer instead of hanging");
    assert!(
        matches!(reused, Err(tablepro_core::DriverError::Disconnected)),
        "a retired connection must report itself disconnected: {reused:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_completed_controlled_statement_leaves_the_connection_usable() {
    let (_c, opts) = start_mssql().await;
    let connection = connect(opts).await;
    let control = tablepro_core::OperationControl::new(tokio_util::sync::CancellationToken::new(), None);

    let first = connection
        .query_controlled("SELECT 1", &control)
        .await
        .expect("an uninterrupted controlled query returns rows");
    assert_eq!(first.rows, vec![vec![Value::Int(1)]]);

    let second = connection.query("SELECT 2").await.expect("the connection stays usable");
    assert_eq!(second.rows, vec![vec![Value::Int(2)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_comment_round_trips_from_its_extended_property() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE comment_demo (id int NOT NULL, label nvarchar(64) NULL)")
        .await
        .unwrap();
    conn.execute(
        "EXEC sp_addextendedproperty @name = N'MS_Description', \
         @value = N'what the row is called', \
         @level0type = N'SCHEMA', @level0name = dbo, \
         @level1type = N'TABLE', @level1name = comment_demo, \
         @level2type = N'COLUMN', @level2name = label",
    )
    .await
    .unwrap();

    let columns = conn.fetch_columns(None, "comment_demo").await.unwrap();
    let id = columns.iter().find(|c| c.name == "id").unwrap();
    let label = columns.iter().find(|c| c.name == "label").unwrap();
    assert_eq!(label.comment.as_deref(), Some("what the row is called"));
    assert_eq!(id.comment, None);
}

async fn session_value(session: &mut Box<dyn tablepro_core::Session>, sql: &str) -> Value {
    let control = tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session.query_params_controlled(sql, &[], &control).await.unwrap().rows[0][0].clone()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_session_keeps_temp_tables_and_its_transaction_between_statements() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE ledger (id int)").await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(30));

    for sql in ["CREATE TABLE #scratch (n int)", "INSERT INTO #scratch VALUES (7)"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT n FROM #scratch").await,
        Value::Int(7)
    );
    for sql in ["BEGIN TRANSACTION", "INSERT INTO ledger VALUES (1)", "ROLLBACK"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT COUNT(*) FROM ledger").await,
        Value::Int(0)
    );
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_interrupted_session_statement_retires_the_session_but_not_the_shared_connection() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;
    let mut session = conn.open_session().await.unwrap();
    let token = tokio_util::sync::CancellationToken::new();
    let control = tablepro_core::OperationControl::new(token.clone(), None);
    let canceller = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        token.cancel();
    });

    let error = session
        .query_params_controlled("WAITFOR DELAY '00:00:30'", &[], &control)
        .await
        .unwrap_err();
    canceller.await.unwrap();

    assert!(
        matches!(error, tablepro_core::DriverError::OperationOutcomeUnknown { .. }),
        "{error:?}"
    );
    assert!(!session.is_usable());
    assert_eq!(conn.query("SELECT 1").await.unwrap().rows, vec![vec![Value::Int(1)]]);
}

async fn notes_in(conn: &dyn Connection, table: &str) -> Vec<String> {
    let rows = conn.query(&format!("SELECT note FROM {table}")).await.unwrap();
    let mut notes: Vec<String> = rows
        .rows
        .iter()
        .map(|row| match &row[0] {
            Value::Text(text) => text.clone(),
            other => panic!("note must be text, got {other:?}"),
        })
        .collect();
    notes.sort();
    notes
}

async fn grid_edits_and_deletes_only_the_keyed_row(conn: &dyn Connection, driver_id: &str, table: &str) {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    let note = columns.iter().position(|c| c.name == "note").unwrap();
    let rows = conn.fetch_rows(None, table, 0, 10).await.unwrap();
    let target = rows
        .rows
        .iter()
        .find(|row| row[note] == Value::Text("target".into()))
        .unwrap();
    let pk_values: Vec<Value> = columns
        .iter()
        .zip(target)
        .filter(|(column, _)| column.primary_key)
        .map(|(_, value)| value.clone())
        .collect();
    assert!(!pk_values.is_empty(), "{table} must report its primary key");
    let before = notes_in(conn, table).await;
    let others: Vec<String> = before.iter().filter(|n| *n != "target").cloned().collect();

    let update = tablepro_core::sql_dialect::build_keyed_update(
        driver_id,
        None,
        table,
        &columns,
        &[(note, Value::Text("edited".into()))],
        &pk_values,
    )
    .unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[update]).await.unwrap(),
        vec![1],
        "{table} update"
    );
    let mut expected = others.clone();
    expected.insert(0, "edited".to_string());
    assert_eq!(
        notes_in(conn, table).await,
        expected,
        "{table} update touched only the keyed row"
    );

    let delete = tablepro_core::sql_dialect::build_keyed_delete(driver_id, None, table, &columns, &pk_values).unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[delete]).await.unwrap(),
        vec![1],
        "{table} delete"
    );
    assert_eq!(
        notes_in(conn, table).await,
        others,
        "{table} delete removed only the keyed row"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn grid_row_edits_find_rows_by_uuid_composite_and_wide_bigint_keys() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;
    for sql in [
        "CREATE TABLE keyed_uuid (id uniqueidentifier PRIMARY KEY, note nvarchar(20))",
        "INSERT INTO keyed_uuid VALUES ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b', N'target'), \
         ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5c', N'other')",
        "CREATE TABLE keyed_composite (tenant int, code nvarchar(10), note nvarchar(20), PRIMARY KEY (tenant, code))",
        "INSERT INTO keyed_composite VALUES (1, N'a', N'target'), (1, N'b', N'other'), (2, N'a', N'other')",
        "CREATE TABLE keyed_bigint (id bigint PRIMARY KEY, note nvarchar(20))",
        "INSERT INTO keyed_bigint VALUES (9007199254740993, N'target'), (9007199254740992, N'other')",
    ] {
        conn.execute(sql).await.unwrap();
    }
    for table in ["keyed_uuid", "keyed_composite", "keyed_bigint"] {
        grid_edits_and_deletes_only_the_keyed_row(conn.as_ref(), "mssql", table).await;
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE binary_exports (id INTEGER, payload VARBINARY(MAX))")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
    let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
    for (id, value) in values.iter().enumerate() {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "mssql",
            None,
            "binary_exports",
            &columns,
            &[Value::Int(id as i64), value.clone()],
        )
        .unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let result = conn
        .query("SELECT payload FROM binary_exports ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        values.into_iter().map(|value| vec![value]).collect::<Vec<_>>()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn sql_exports_preserve_unicode_and_boolean_values() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE literal_exports (label nvarchar(max), enabled bit)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "literal_exports").await.unwrap();
    let row = vec![Value::Text("漢字 😀 O'Brien \\".into()), Value::Bool(true)];
    let sql =
        tablepro_core::sql_literal::build_insert_literal("mssql", None, "literal_exports", &columns, &row).unwrap();
    conn.execute(&sql).await.unwrap();
    assert_eq!(
        conn.query("SELECT label, enabled FROM literal_exports")
            .await
            .unwrap()
            .rows,
        vec![row]
    );
}

#[path = "../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let (_container, options) = start_mssql().await;
    let connection = connect(options).await;
    value_contract::assert_scalar_contract(connection.as_ref(), "mssql").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn inexact_legacy_datetime_uses_exact_text_and_supported_temporals_round_trip() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute(
        "CREATE TABLE temporal_source (id int, legacy datetime, small smalldatetime, precise datetime2(7), \
         clock time(7), day date)",
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO temporal_source VALUES \
         (1, '2024-01-02 03:04:05.997', '2024-01-02 03:04:00', '2024-01-02 03:04:05.1234567', \
          '03:04:05.1234567', '0001-01-01'), \
         (2, '1753-01-01 00:00:00.003', '1900-01-01 00:00:00', '9999-12-31 23:59:59.9999999', \
          '23:59:59.9999999', '9999-12-31')",
    )
    .await
    .unwrap();
    let rows = conn
        .query("SELECT * FROM temporal_source ORDER BY id")
        .await
        .unwrap()
        .rows;
    let legacy_oracle = conn
        .query(
            "SELECT id, legacy, CONVERT(varchar(27), legacy, 126) AS native_text \
             FROM temporal_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(legacy_oracle.rows[0][1], Value::Text("2024-01-02T03:04:05.997".into()));
    assert_eq!(legacy_oracle.rows[0][2], Value::Text("2024-01-02T03:04:05.997".into()));
    assert_eq!(legacy_oracle.rows[1][1], Value::Text("1753-01-01T00:00:00.003".into()));
    assert_eq!(legacy_oracle.rows[1][2], Value::Text("1753-01-01T00:00:00.003".into()));

    conn.execute("CREATE TABLE temporal_legacy_exported (id int, legacy datetime)")
        .await
        .unwrap();
    let legacy_columns = conn.fetch_columns(None, "temporal_legacy_exported").await.unwrap();
    for row in &rows {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "mssql",
            None,
            "temporal_legacy_exported",
            &legacy_columns,
            &row[..2],
        )
        .expect("legacy datetime text fallback should be exportable");
        conn.execute(&statement)
            .await
            .unwrap_or_else(|error| panic!("{statement}: {error}"));
    }
    let literal_matches = conn
        .query(
            "SELECT COUNT(*) FROM temporal_source s JOIN temporal_legacy_exported c \
         ON s.id = c.id AND CONVERT(varbinary(8), s.legacy) = CONVERT(varbinary(8), c.legacy)",
        )
        .await
        .unwrap();
    assert_eq!(literal_matches.rows, vec![vec![Value::Int(2)]]);

    let precise = conn
        .query(
            "SELECT precise, CONVERT(varchar(27), precise, 126) AS native_text \
             FROM temporal_source WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(
        precise.rows[0][0],
        Value::DateTime(
            NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_time(NaiveTime::from_hms_nano_opt(3, 4, 5, 123_456_700).unwrap())
        )
    );
    assert_eq!(precise.rows[0][1], Value::Text("2024-01-02T03:04:05.1234567".into()));

    conn.execute(
        "CREATE TABLE temporal_exported (id int, small smalldatetime, precise datetime2(7), clock time(7), day date)",
    )
    .await
    .unwrap();
    let columns = conn.fetch_columns(None, "temporal_exported").await.unwrap();
    let supported_rows = conn
        .query("SELECT id, small, precise, clock, day FROM temporal_source ORDER BY id")
        .await
        .unwrap()
        .rows;
    for row in &supported_rows {
        let statement =
            tablepro_core::sql_literal::build_insert_literal("mssql", None, "temporal_exported", &columns, row)
                .expect("supported temporal columns should be exportable");
        conn.execute(&statement)
            .await
            .unwrap_or_else(|error| panic!("{statement}: {error}"));
    }
    let matching = conn
        .query(
            "SELECT COUNT(*) FROM temporal_source s JOIN temporal_exported c ON s.id = c.id \
             AND s.small = c.small AND s.precise = c.precise AND s.clock = c.clock AND s.day = c.day",
        )
        .await
        .unwrap();
    assert_eq!(matching.rows, vec![vec![Value::Int(2)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_all_legacy_datetime_ticks_round_trip_through_parameters() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute(
        "CREATE TABLE legacy_ticks (value datetime); \
         CREATE TABLE legacy_ticks_bound (value datetime)",
    )
    .await
    .unwrap();
    let seed = conn
        .query(
            ";WITH millis AS (SELECT 0 AS n UNION ALL SELECT n + 1 FROM millis WHERE n < 998) \
         INSERT INTO legacy_ticks SELECT DISTINCT CONVERT(datetime, DATEADD(millisecond, n, \
         CONVERT(datetime2(3), '2024-01-02T03:04:05.000'))) FROM millis OPTION (MAXRECURSION 0)",
        )
        .await;
    assert!(seed.is_ok(), "generate all 300 server datetime ticks: {seed:?}");

    let source = conn
        .query(
            "SELECT value, CONVERT(varchar(23), value, 126) AS native_text \
         FROM legacy_ticks ORDER BY value",
        )
        .await
        .unwrap();
    assert_eq!(
        source.rows.len(),
        300,
        "the millisecond sweep must cover each 1/300-second tick"
    );
    let mut parameters = Vec::with_capacity(source.rows.len());
    let mut typed_count = 0;
    let mut text_count = 0;
    for row in &source.rows {
        match &row[0] {
            Value::Text(_) => {
                text_count += 1;
                assert_eq!(row[0], row[1], "fallback must equal native style-126 text");
            }
            Value::DateTime(stamp) => {
                typed_count += 1;
                let expected = chrono::NaiveDateTime::parse_from_str(
                    match &row[1] {
                        Value::Text(text) => text,
                        other => panic!("native text: {other:?}"),
                    },
                    "%Y-%m-%dT%H:%M:%S%.f",
                )
                .unwrap();
                assert_eq!(stamp, &expected, "exact datetime tick must retain its typed value");
            }
            other => panic!("unexpected legacy datetime carrier: {other:?}"),
        }
        parameters.push(row[0].clone());
    }
    assert_eq!(parameters.len(), 300);
    assert_eq!(typed_count, 100, "one third of legacy ticks are exact nanoseconds");
    assert_eq!(text_count, 200, "two thirds require the exact text fallback");
    let placeholders = (1..=parameters.len())
        .map(|i| format!("(@P{i})"))
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!("INSERT INTO legacy_ticks_bound VALUES {placeholders}");
    conn.execute_params(&sql, &parameters).await.unwrap();

    let comparisons = conn
        .query(
            "SELECT COUNT(*), SUM(CASE WHEN CONVERT(varbinary(8), s.value) = \
         CONVERT(varbinary(8), b.value) THEN 1 ELSE 0 END) \
         FROM legacy_ticks s CROSS JOIN legacy_ticks_bound b \
         WHERE CONVERT(varchar(23), s.value, 126) = CONVERT(varchar(23), b.value, 126)",
        )
        .await
        .unwrap();
    assert_eq!(comparisons.rows, vec![vec![Value::Int(300), Value::Int(300)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_smalldatetime_rounding_matches_server_text() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    let result = conn
        .query(
            "SELECT CAST('2024-01-02T03:04:29.998' AS smalldatetime) AS below, \
             CONVERT(varchar(19), CAST('2024-01-02T03:04:29.998' AS smalldatetime), 126) AS below_text, \
             CAST('2024-01-02T03:04:29.999' AS smalldatetime) AS above, \
             CONVERT(varchar(19), CAST('2024-01-02T03:04:29.999' AS smalldatetime), 126) AS above_text, \
             CAST('2024-12-31T23:59:29.998' AS smalldatetime) AS year_end_below, \
             CONVERT(varchar(19), CAST('2024-12-31T23:59:29.998' AS smalldatetime), 126) AS year_end_below_text, \
             CAST('2024-12-31T23:59:29.999' AS smalldatetime) AS year_end_above, \
             CONVERT(varchar(19), CAST('2024-12-31T23:59:29.999' AS smalldatetime), 126) AS year_end_above_text",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::DateTime(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .unwrap()
                    .and_hms_opt(3, 4, 0)
                    .unwrap()
            ),
            Value::Text("2024-01-02T03:04:00".into()),
            Value::DateTime(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .unwrap()
                    .and_hms_opt(3, 5, 0)
                    .unwrap()
            ),
            Value::Text("2024-01-02T03:05:00".into()),
            Value::DateTime(
                NaiveDate::from_ymd_opt(2024, 12, 31)
                    .unwrap()
                    .and_hms_opt(23, 59, 0)
                    .unwrap()
            ),
            Value::Text("2024-12-31T23:59:00".into()),
            Value::DateTime(
                NaiveDate::from_ymd_opt(2025, 1, 1)
                    .unwrap()
                    .and_hms_opt(0, 0, 0)
                    .unwrap()
            ),
            Value::Text("2025-01-01T00:00:00".into()),
        ]]
    );

    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let mapping = (0..result.columns.len()).map(Some).collect::<Vec<_>>();
    let imported =
        tablepro_core::import::row_to_values(&sheet.rows[0], &mapping, &result.columns, &options, 2).unwrap();
    assert_eq!(imported, result.rows[0]);

    conn.execute(
        "CREATE TABLE smalldatetime_year_end_csv_copy \
         (below smalldatetime, above smalldatetime, year_end_below smalldatetime, year_end_above smalldatetime)",
    )
    .await
    .unwrap();
    conn.execute_params(
        "INSERT INTO smalldatetime_year_end_csv_copy VALUES (@P1, @P2, @P3, @P4)",
        &[
            imported[0].clone(),
            imported[2].clone(),
            imported[4].clone(),
            imported[6].clone(),
        ],
    )
    .await
    .unwrap();
    let restored = conn
        .query(
            "SELECT CONVERT(varchar(19), below, 126), CONVERT(varchar(19), above, 126), \
             CONVERT(varchar(19), year_end_below, 126), CONVERT(varchar(19), year_end_above, 126) \
             FROM smalldatetime_year_end_csv_copy",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![vec![
            Value::Text("2024-01-02T03:04:00".into()),
            Value::Text("2024-01-02T03:05:00".into()),
            Value::Text("2024-12-31T23:59:00".into()),
            Value::Text("2025-01-01T00:00:00".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_legacy_datetime_fallback_matches_session_batch_and_native_text() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    let sql = "SELECT value, CONVERT(varchar(23), value, 126) AS server_text \
             FROM (VALUES \
             (1, CAST('2024-01-02T03:04:05.001' AS datetime)), \
             (2, CAST('2024-01-02T03:04:05.002' AS datetime)), \
             (3, CAST('2024-01-02T03:04:05.004' AS datetime)), \
             (4, CAST('2024-01-02T03:04:05.005' AS datetime)), \
             (5, CAST('2024-01-02T03:04:05.008' AS datetime)) \
             ) AS samples(id, value) ORDER BY id";
    let result = conn.query(sql).await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let session_result = session
        .query_params_controlled(sql, &[], &control)
        .await
        .expect("read inexact legacy datetime through the session batch path");
    assert_eq!(session_result.columns, result.columns);
    assert_eq!(session_result.rows, result.rows);
    session.close().await.unwrap();
    let expected_server_text = [
        "2024-01-02T03:04:05",
        "2024-01-02T03:04:05.003",
        "2024-01-02T03:04:05.003",
        "2024-01-02T03:04:05.007",
        "2024-01-02T03:04:05.007",
    ];
    let expected_values = [
        Value::DateTime(
            NaiveDate::from_ymd_opt(2024, 1, 2)
                .unwrap()
                .and_hms_opt(3, 4, 5)
                .unwrap(),
        ),
        Value::Text("2024-01-02T03:04:05.003".into()),
        Value::Text("2024-01-02T03:04:05.003".into()),
        Value::Text("2024-01-02T03:04:05.007".into()),
        Value::Text("2024-01-02T03:04:05.007".into()),
    ];
    assert_eq!(result.rows.len(), expected_server_text.len());
    for ((row, expected_value), expected_text) in result.rows.iter().zip(expected_values).zip(expected_server_text) {
        assert_eq!(row[0], expected_value);
        assert_eq!(row[1], Value::Text(expected_text.into()));
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_money_values_are_refused_but_server_nulls_remain_null() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE money_source (id int PRIMARY KEY, amount money, small_amount smallmoney)")
        .await
        .unwrap();
    conn.execute("INSERT INTO money_source VALUES (1, 123456789012345.6789, -123456.7891)")
        .await
        .unwrap();
    conn.execute("INSERT INTO money_source VALUES (2, NULL, NULL)")
        .await
        .unwrap();

    let result = conn
        .query(
            "SELECT amount, CONVERT(varchar(40), CAST(amount AS decimal(19,4))) AS amount_text, \
             small_amount, CONVERT(varchar(40), CAST(small_amount AS decimal(10,4))) AS small_text \
             FROM money_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.rows[0][1], Value::Text("123456789012345.6789".into()));
    assert_eq!(result.rows[0][3], Value::Text("-123456.7891".into()));
    assert_eq!(result.rows[0][0], Value::Undecodable("money".into()));
    assert_eq!(result.rows[0][2], Value::Undecodable("money".into()));
    assert_eq!(result.rows[1], vec![Value::Null, Value::Null, Value::Null, Value::Null]);
}

const ZONED_STAMPS: [&str; 5] = [
    "2024-01-02 03:04:05.1234567 +05:30",
    "2024-06-30 23:59:59.9999999 -08:00",
    "2024-12-31 00:00:00.0000001 +14:00",
    "0001-01-01 00:00:00.0000000 -14:00",
    "9999-12-31 23:59:59.9999999 +00:00",
];

async fn zoned_copies_matching(conn: &dyn Connection, copy: &str) -> Value {
    let sql = format!(
        "SELECT COUNT(*) FROM zoned_source s JOIN {copy} c ON s.id = c.id AND s.zoned = c.zoned \
         AND DATEPART(TZOFFSET, s.zoned) = DATEPART(TZOFFSET, c.zoned)"
    );
    conn.query(&sql).await.unwrap().rows[0][0].clone()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_datetimeoffset_keeps_its_offset_through_results_parameters_and_exports() {
    let (_container, options) = start_mssql().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE zoned_source (id int, zoned datetimeoffset(7))")
        .await
        .unwrap();
    for (id, stamp) in ZONED_STAMPS.iter().enumerate() {
        conn.execute(&format!("INSERT INTO zoned_source VALUES ({id}, '{stamp}')"))
            .await
            .unwrap();
    }
    let select = "SELECT id, zoned FROM zoned_source ORDER BY id";
    let source = conn.query(select).await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let session_source = session
        .query_params_controlled(select, &[], &control)
        .await
        .expect("read datetimeoffset values through the session batch path");
    assert_eq!(session_source.columns, source.columns);
    assert_eq!(session_source.rows, source.rows);
    session.close().await.unwrap();
    let rows = source.rows.clone();
    let decoded: Vec<Value> = rows.iter().map(|row| row[1].clone()).collect();
    let expected: Vec<Value> = ZONED_STAMPS.iter().map(|stamp| Value::Text((*stamp).into())).collect();
    assert_eq!(decoded, expected);
    for copy in ["zoned_bound", "zoned_exported"] {
        conn.execute(&format!("SELECT * INTO {copy} FROM zoned_source WHERE 1 = 0"))
            .await
            .unwrap();
    }
    let columns = conn.fetch_columns(None, "zoned_exported").await.unwrap();
    for row in &rows {
        conn.execute_params("INSERT INTO zoned_bound VALUES (@P1, @P2)", row)
            .await
            .unwrap();
        let statement =
            tablepro_core::sql_literal::build_insert_literal("mssql", None, "zoned_exported", &columns, row).unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let total = Value::Int(ZONED_STAMPS.len() as i64);
    assert_eq!(zoned_copies_matching(conn.as_ref(), "zoned_bound").await, total);
    assert_eq!(zoned_copies_matching(conn.as_ref(), "zoned_exported").await, total);
    datetimeoffset_csv::assert_csv_round_trip(conn.as_ref(), &source).await;
}
