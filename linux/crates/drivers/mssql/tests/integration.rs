use std::str::FromStr;

use chrono::{NaiveDate, NaiveTime};
use rust_decimal::Decimal;
use secrecy::SecretString;

use drivers_mssql::MssqlDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};
use testcontainers::ContainerAsync;
use testcontainers_modules::mssql_server::MssqlServer;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

async fn start_mssql() -> (ContainerAsync<MssqlServer>, ConnectOptions) {
    let container = MssqlServer::default()
        .with_accept_eula()
        .start()
        .await
        .expect("start mssql container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(1433).await.expect("port");
    let opts = ConnectOptions {
        host,
        port,
        database: "master".into(),
        username: "sa".into(),
        password: SecretString::new(MssqlServer::DEFAULT_SA_PASSWORD.to_string().into()),
        use_tls: false,
        ..Default::default()
    };
    (container, opts)
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
    let (_c, opts) = start_mssql().await;
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
    };
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "def_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let status = |cols: Vec<tablepro_core::ColumnInfo>| cols.into_iter().find(|c| c.name == "status").unwrap();
    let after_add = status(conn.fetch_columns(None, "def_demo").await.unwrap());
    assert_eq!(after_add.default_value.as_deref(), Some("pending"));

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
