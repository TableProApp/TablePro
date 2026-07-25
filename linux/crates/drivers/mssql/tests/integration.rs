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
