use std::str::FromStr;

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use rust_decimal::Decimal;
use serde_json::json;

use drivers_mysql::MysqlDriver;
use tablepro_core::value::{JsonText, OffsetTimestamp, SqlTime, Temporal};
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};
use testcontainers::ImageExt;
use testcontainers::{ContainerAsync, TestcontainersError};
use testcontainers_modules::mysql::Mysql;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

async fn start_mysql() -> Result<(ContainerAsync<Mysql>, ConnectOptions), TestcontainersError> {
    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .start()
        .await?;
    let host = container.get_host().await?.to_string();
    let port = container.get_host_port_ipv4(3306).await?;
    let opts = ConnectOptions {
        host,
        port,
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        use_tls: false,
        ..Default::default()
    };
    Ok((container, opts))
}

async fn start_caching_sha2() -> Result<(ContainerAsync<Mysql>, ConnectOptions), TestcontainersError> {
    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .start()
        .await?;
    let host = container.get_host().await?.to_string();
    let port = container.get_host_port_ipv4(3306).await?;
    let opts = ConnectOptions {
        host,
        port,
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        use_tls: false,
        ..Default::default()
    };
    Ok((container, opts))
}

// caching_sha2_password over a plaintext connection falls back to full
// authentication, where the client encrypts the password with the
// server's public key. Without sqlx's mysql-rsa feature that path fails
// at runtime, so a successful connect is the assertion.
#[tokio::test]
#[ignore = "requires docker"]
async fn caching_sha2_without_tls_uses_rsa() {
    let (_c, opts) = start_caching_sha2().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    let plugin = conn
        .query("SELECT CAST(plugin AS CHAR) FROM mysql.user WHERE user = 'root' AND host = '%'")
        .await
        .unwrap();

    assert_eq!(plugin.rows[0][0], Value::Text("caching_sha2_password".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_and_pk_detection() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE pk_demo (
            id int AUTO_INCREMENT PRIMARY KEY,
            name varchar(255) NOT NULL,
            note text NULL
        )",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO pk_demo (name, note) VALUES ('a', NULL), ('b', 'second')")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "pk_demo"));

    let cols = conn.fetch_columns(None, "pk_demo").await.unwrap();
    assert_eq!(cols.len(), 3);
    let id_col = cols.iter().find(|c| c.name == "id").unwrap();
    assert!(id_col.primary_key, "id must be detected as primary key");
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
async fn value_roundtrip_all_types() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE roundtrip (
            id int AUTO_INCREMENT PRIMARY KEY,
            b tinyint(1),
            i_small smallint,
            i_medium mediumint,
            i_big bigint,
            f_single float,
            f_double double,
            num decimal(20,5),
            t text,
            bytes varbinary(64),
            d date,
            tm time,
            dt datetime,
            ts timestamp NULL,
            u varchar(36),
            j json,
            nullable_text text NULL
        )",
    )
    .await
    .unwrap();

    let date = NaiveDate::from_ymd_opt(2024, 6, 15).unwrap();
    let time = NaiveTime::from_hms_opt(13, 45, 30).unwrap();
    let dt = NaiveDateTime::new(date, time);
    let tz: DateTime<Utc> = Utc.with_ymd_and_hms(2024, 6, 15, 13, 45, 30).unwrap();
    let uuid = uuid::Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    let dec = Decimal::from_str("12345.67890").unwrap();
    let json_val = json!({"k": [1, 2, 3], "nested": {"flag": true}});

    let params = vec![
        Value::Bool(true),
        Value::Int(123),
        Value::Int(456_789),
        Value::Int(9_000_000_000_000_000_000),
        Value::Float64(1.5_f64),
        Value::Float64(std::f64::consts::PI),
        Value::Decimal(dec.to_string().parse().expect("a decimal")),
        Value::Text("hello\nworld".into()),
        Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]),
        Value::Date(Temporal::Finite(date)),
        Value::Time(SqlTime::from_time_of_day(time)),
        Value::Timestamp(Temporal::Finite(dt)),
        Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(tz.fixed_offset()))),
        Value::Uuid(uuid),
        Value::Json(JsonText::parse(json_val.to_string()).expect("valid json")),
        Value::Null,
    ];

    let res = conn
        .execute_params(
            "INSERT INTO roundtrip
             (b, i_small, i_medium, i_big, f_single, f_double, num, t, bytes, d, tm, dt, ts, u, j, nullable_text)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            &params,
        )
        .await
        .unwrap();
    assert_eq!(res.rows_affected, 1);

    let q = conn
        .query(
            "SELECT b, i_small, i_medium, i_big, f_single, f_double, num, t, bytes, d, tm, dt, ts, u, j, nullable_text
             FROM roundtrip ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(q.rows.len(), 1);
    let row = &q.rows[0];

    match &row[0] {
        Value::Bool(true) => {}
        Value::Int(1) => {}
        v => panic!("expected tinyint(1) -> Bool(true) or Int(1), got {v:?}"),
    }
    assert!(matches!(row[1], Value::Int(123)));
    assert!(matches!(row[2], Value::Int(456_789)));
    assert!(matches!(row[3], Value::Int(9_000_000_000_000_000_000)));
    // A single-precision float keeps its own width: widening it to
    // f64 and back does not round-trip.
    match &row[4] {
        Value::Float32(f) => assert_eq!(*f, 1.5_f32),
        v => panic!("expected a 32-bit float, got {v:?}"),
    }
    match &row[5] {
        Value::Float64(f) => assert!((*f - std::f64::consts::PI).abs() < 1e-9),
        v => panic!("expected double, got {v:?}"),
    }
    match &row[6] {
        Value::Decimal(d) => assert_eq!(d.to_string(), "12345.67890"),
        v => panic!("expected decimal, got {v:?}"),
    }
    assert_eq!(row[7], Value::Text("hello\nworld".into()));
    assert_eq!(row[8], Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]));
    assert_eq!(row[9], Value::Date(Temporal::Finite(date)));
    assert_eq!(row[10], Value::Time(SqlTime::from_time_of_day(time)));
    assert_eq!(row[11], Value::Timestamp(Temporal::Finite(dt)));
    assert_eq!(
        row[12],
        Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(tz.fixed_offset())))
    );
    match &row[13] {
        Value::Text(s) => assert_eq!(s, "550e8400-e29b-41d4-a716-446655440000"),
        v => panic!("expected uuid as text, got {v:?}"),
    }
    // The document comes back the way the server prints it, not the
    // way it was written: MySQL stores a parsed document, so the grid
    // shows the server's own rendering.
    match &row[14] {
        Value::Json(v) => assert_eq!(v.as_str(), r#"{"k": [1, 2, 3], "nested": {"flag": true}}"#),
        v => panic!("expected json, got {v:?}"),
    }
    assert_eq!(row[15], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pagination_and_truncated_flag() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    conn.execute("CREATE TABLE big (i int PRIMARY KEY)").await.unwrap();
    let mut sql = String::from("INSERT INTO big (i) VALUES ");
    for i in 0..50 {
        if i > 0 {
            sql.push(',');
        }
        sql.push_str(&format!("({i})"));
    }
    conn.execute(&sql).await.unwrap();

    let page = conn.fetch_rows(None, "big", 10, 5).await.unwrap();
    assert_eq!(page.rows.len(), 5);
    let firsts: Vec<i64> = page
        .rows
        .iter()
        .map(|r| match r[0] {
            Value::Int(i) => i,
            _ => panic!(),
        })
        .collect();
    assert_eq!(firsts, vec![10, 11, 12, 13, 14]);

    let q = conn.query("SELECT i FROM big ORDER BY i").await.unwrap();
    assert_eq!(q.rows.len(), 50);
    assert!(!q.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    let err = conn.query("SELECT * FROM no_such_table").await.unwrap_err();
    let msg = format!("{err}").to_lowercase();
    assert!(
        msg.contains("no_such_table") || msg.contains("doesn't exist") || msg.contains("table"),
        "expected error to mention missing table, got: {msg}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn wire_only_types_read_back() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE wire_types (
            id int AUTO_INCREMENT PRIMARY KEY,
            big_unsigned bigint unsigned,
            small_unsigned smallint unsigned,
            made_in year,
            flags bit(8),
            span time,
            wide decimal(40,10),
            nothing decimal(10,2)
        )",
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO wire_types (big_unsigned, small_unsigned, made_in, flags, span, wide, nothing)
         VALUES (18446744073709551615, 65535, 2024, b'10110011', '-838:59:59',
                 1234567890123456789012345678.9012345678, NULL)",
    )
    .await
    .unwrap();

    let q = conn
        .query(
            "SELECT big_unsigned, small_unsigned, made_in, flags, span, wide, nothing
             FROM wire_types",
        )
        .await
        .unwrap();
    let row = &q.rows[0];

    // Past what a signed 64-bit integer holds, so a widening decode
    // would wrap it into a negative.
    assert_eq!(row[0], Value::UInt(u64::MAX));
    assert_eq!(row[1], Value::UInt(65535));
    assert_eq!(row[2], Value::UInt(2024));
    match &row[3] {
        Value::Bits(b) => assert_eq!(b.to_string(), "10110011"),
        v => panic!("expected bits, got {v:?}"),
    }
    match &row[4] {
        Value::Time(t) => assert_eq!(t.format(None), "-838:59:59"),
        v => panic!("expected a time span, got {v:?}"),
    }
    match &row[5] {
        Value::Decimal(d) => assert_eq!(d.to_string(), "1234567890123456789012345678.9012345678"),
        v => panic!("expected a wide decimal, got {v:?}"),
    }
    // A NULL in a type the driver reads through the wire form still
    // reads as a NULL, not as an unreadable value.
    assert_eq!(row[6], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn column_comments_round_trip() {
    let (_c, opts) = start_mysql().await.unwrap();
    let conn = MysqlDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE comment_demo (
            id INT,
            email VARCHAR(255) COMMENT 'primary contact'
        )",
    )
    .await
    .unwrap();

    let read =
        |cols: Vec<tablepro_core::ColumnInfo>, name: &str| cols.into_iter().find(|c| c.name == name).unwrap().comment;
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols.clone(), "email").as_deref(), Some("primary contact"));
    // MySQL stores the empty string for a column nobody described, and
    // that has to read as absent rather than as an empty description.
    assert_eq!(read(cols.clone(), "id"), None);

    let mut column =
        tablepro_core::sql_ddl::DraftColumn::from_info(cols.into_iter().find(|c| c.name == "email").unwrap());
    column.comment = Some("who to mail".into());
    for sql in tablepro_core::sql_ddl::build_alter_column("mysql", None, "comment_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols.clone(), "email").as_deref(), Some("who to mail"));

    // A change to something else must not take the description with
    // it: MODIFY COLUMN replaces the whole definition.
    let mut column =
        tablepro_core::sql_ddl::DraftColumn::from_info(cols.into_iter().find(|c| c.name == "email").unwrap());
    column.nullable = false;
    for sql in tablepro_core::sql_ddl::build_alter_column("mysql", None, "comment_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols.clone(), "email").as_deref(), Some("who to mail"));

    let mut column =
        tablepro_core::sql_ddl::DraftColumn::from_info(cols.into_iter().find(|c| c.name == "email").unwrap());
    column.comment = None;
    for sql in tablepro_core::sql_ddl::build_alter_column("mysql", None, "comment_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols, "email"), None);
}
