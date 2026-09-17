use std::str::FromStr;

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use rust_decimal::Decimal;
use serde_json::json;
use uuid::Uuid;

use drivers_postgres::PgDriver;
use tablepro_core::value::{JsonText, OffsetTimestamp, SqlTime, Temporal};
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};
use testcontainers::ImageExt;
use testcontainers::{ContainerAsync, TestcontainersError};
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

async fn start_pg() -> Result<(ContainerAsync<Postgres>, ConnectOptions), TestcontainersError> {
    // Pin to Postgres 16: the introspection query in `fetch_columns`
    // reads `pg_attribute.attgenerated`, which was added in PG 12.
    // testcontainers-modules's default tag is older and breaks the
    // generated-column flag query. PG 11 hit upstream EOL in Nov 2023
    // so production deployments shouldn't be older than this anyway.
    let container = Postgres::default().with_tag("16-alpine").start().await?;
    let host = container.get_host().await?.to_string();
    let port = container.get_host_port_ipv4(5432).await?;
    let opts = ConnectOptions {
        host,
        port,
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new("postgres".to_string().into()),
        use_tls: false,
        ..Default::default()
    };
    Ok((container, opts))
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_and_pk_detection() {
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE pk_demo (
            id serial PRIMARY KEY,
            name text NOT NULL,
            note text
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
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE roundtrip (
            id serial PRIMARY KEY,
            b bool,
            i2 smallint,
            i4 integer,
            i8 bigint,
            f4 real,
            f8 double precision,
            num numeric(20,5),
            t text,
            bytes bytea,
            d date,
            tm time,
            dt timestamp,
            tz timestamptz,
            u uuid,
            j jsonb,
            nullable_text text
        )",
    )
    .await
    .unwrap();

    let date = NaiveDate::from_ymd_opt(2024, 6, 15).unwrap();
    let time = NaiveTime::from_hms_opt(13, 45, 30).unwrap();
    let dt = NaiveDateTime::new(date, time);
    let tz: DateTime<Utc> = Utc.with_ymd_and_hms(2024, 6, 15, 13, 45, 30).unwrap();
    let uuid = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    let dec = Decimal::from_str("12345.67890").unwrap();
    let json_val = json!({"k": [1, 2, 3], "nested": {"flag": true}});

    let params = vec![
        Value::Bool(true),
        Value::Int(123),
        Value::Int(2_000_000_000),
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
             (b, i2, i4, i8, f4, f8, num, t, bytes, d, tm, dt, tz, u, j, nullable_text)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)",
            &params,
        )
        .await
        .unwrap();
    assert_eq!(res.rows_affected, 1);

    let q = conn
        .query(
            "SELECT b, i2, i4, i8, f4, f8, num, t, bytes, d, tm, dt, tz, u, j, nullable_text
             FROM roundtrip ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(q.rows.len(), 1);
    let row = &q.rows[0];

    assert!(matches!(row[0], Value::Bool(true)));
    assert!(matches!(row[1], Value::Int(123)));
    assert!(matches!(row[2], Value::Int(2_000_000_000)));
    assert!(matches!(row[3], Value::Int(9_000_000_000_000_000_000)));
    // A real keeps its own width: widening it to f64 and back does
    // not round-trip.
    match &row[4] {
        Value::Float32(f) => assert_eq!(*f, 1.5_f32),
        v => panic!("expected a 32-bit float, got {v:?}"),
    }
    match &row[5] {
        Value::Float64(f) => assert!((*f - std::f64::consts::PI).abs() < 1e-9),
        v => panic!("expected float, got {v:?}"),
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
    assert_eq!(row[13], Value::Uuid(uuid));
    // The document comes back the way jsonb prints it, not the way
    // it was written: jsonb stores a parsed document, so the grid
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
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

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
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

    let err = conn.query("SELECT * FROM no_such_table").await.unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.to_lowercase().contains("no_such_table") || msg.to_lowercase().contains("relation"),
        "expected error to mention missing relation, got: {msg}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn binary_only_types_read_back() {
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

    conn.execute(
        "CREATE TABLE wire_types (
            id serial PRIMARY KEY,
            wide numeric,
            bits bit(5),
            varying_bits varbit,
            span interval,
            clock timetz,
            nothing numeric
        )",
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO wire_types (wide, bits, varying_bits, span, clock, nothing)
         VALUES (123456789012345678901234567890.123456789,
                 B'10110',
                 B'1101',
                 INTERVAL '1 year 2 mons 3 days 04:05:06.5',
                 TIMETZ '13:45:30+07:00',
                 NULL)",
    )
    .await
    .unwrap();

    let q = conn
        .query("SELECT wide, bits, varying_bits, span, clock, nothing FROM wire_types")
        .await
        .unwrap();
    let row = &q.rows[0];

    match &row[0] {
        Value::Decimal(d) => assert_eq!(d.to_string(), "123456789012345678901234567890.123456789"),
        v => panic!("expected a numeric past 28 digits, got {v:?}"),
    }
    match &row[1] {
        Value::Bits(b) => assert_eq!(b.to_string(), "10110"),
        v => panic!("expected bits, got {v:?}"),
    }
    match &row[2] {
        Value::Bits(b) => assert_eq!(b.to_string(), "1101"),
        v => panic!("expected varying bits, got {v:?}"),
    }
    match &row[3] {
        Value::Interval(i) => {
            assert_eq!(i.months, 14);
            assert_eq!(i.days, 3);
            assert_eq!(i.microseconds, 14_706_500_000);
        }
        v => panic!("expected an interval, got {v:?}"),
    }
    match &row[4] {
        Value::TimeTz(t) => {
            let expected = NaiveTime::from_hms_opt(13, 45, 30).expect("a time");
            assert_eq!(t.time, SqlTime::from_time_of_day(expected));
            assert_eq!(t.offset.local_minus_utc(), 7 * 3600);
        }
        v => panic!("expected a time with offset, got {v:?}"),
    }
    // A NULL in a type the driver reads through the wire form still
    // reads as a NULL, not as an unreadable value.
    assert_eq!(row[5], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn column_comments_round_trip() {
    let (_c, opts) = start_pg().await.unwrap();
    let conn = PgDriver.connect(opts).await.unwrap();

    conn.execute("CREATE TABLE comment_demo (id integer, email text)")
        .await
        .unwrap();
    conn.execute("COMMENT ON COLUMN comment_demo.email IS 'primary contact'")
        .await
        .unwrap();

    let read =
        |cols: Vec<tablepro_core::ColumnInfo>, name: &str| cols.into_iter().find(|c| c.name == name).unwrap().comment;
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols.clone(), "email").as_deref(), Some("primary contact"));
    assert_eq!(read(cols.clone(), "id"), None);

    let mut column =
        tablepro_core::sql_ddl::DraftColumn::from_info(cols.into_iter().find(|c| c.name == "email").unwrap());
    column.comment = Some("who to mail".into());
    for sql in tablepro_core::sql_ddl::build_alter_column("postgres", None, "comment_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols.clone(), "email").as_deref(), Some("who to mail"));

    column = tablepro_core::sql_ddl::DraftColumn::from_info(cols.into_iter().find(|c| c.name == "email").unwrap());
    column.comment = None;
    for sql in tablepro_core::sql_ddl::build_alter_column("postgres", None, "comment_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    assert_eq!(read(cols, "email"), None);
}
