//! Values read back exactly, through the same paths browse and the
//! editor use.

use chrono::DateTime;
use tablepro_core::value::{OffsetTimestamp, SqlDecimal, Temporal};
use tablepro_core::{Connection, Value};

use crate::support::{browse, columns, connect, dbo, insert_one, rows, run_ok, scalar, session, setup, start, write};

fn decimal(text: &str) -> Value {
    Value::Decimal(text.parse::<SqlDecimal>().expect("a decimal"))
}

fn text(value: &Value) -> String {
    match value {
        Value::Text(text) => text.clone(),
        other => format!("not text: {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn serverproperty_product_version_no_panic() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    let version = scalar(connection.as_ref(), "SELECT SERVERPROPERTY('ProductVersion')").await;

    assert!(connection.server_info().major >= 16, "{:?}", connection.server_info());
    assert!(text(&version).starts_with(&connection.server_info().major.to_string()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn sql_variant_int_nvarchar_datetime2() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    let row = rows(
        connection.as_ref(),
        "SELECT CAST(42 AS sql_variant), CAST(N'zoë' AS sql_variant), \
         CAST(CAST('2024-06-15T10:00:00.1234567' AS datetime2(7)) AS sql_variant)",
    )
    .await
    .remove(0);

    assert_eq!(row[0], Value::Int(42));
    assert_eq!(row[1], Value::Text("zoë".to_owned()));
    let Value::Timestamp(Temporal::Finite(stamp)) = &row[2] else {
        panic!("not a timestamp: {:?}", row[2]);
    };
    assert_eq!(
        stamp.format("%Y-%m-%dT%H:%M:%S%.9f").to_string(),
        "2024-06-15T10:00:00.123456700"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn geography_hierarchyid_browse_projects_text_value_slash_1_2() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.places (id int PRIMARY KEY, node hierarchyid, spot geography)",
            "INSERT INTO dbo.places VALUES (1, hierarchyid::Parse('/1/2/'), geography::Point(47.65, -122.34, 4326))",
        ],
    )
    .await;

    let row = browse(connection.as_ref(), &dbo("places")).await.remove(0);

    assert_eq!(row[1], Value::Text("/1/2/".to_owned()));
    assert!(text(&row[2]).starts_with("POINT ("), "{:?}", row[2]);
}

async fn money_round_trip(connection: &dyn Connection, declared: &str, max: &str, min: &str) {
    let create = format!("CREATE TABLE dbo.prices (id int PRIMARY KEY, price {declared})");
    let insert = format!("INSERT INTO dbo.prices VALUES (1, {max}), (2, {min})");
    setup(connection, &[&create, &insert]).await;

    let rows = browse(connection, &dbo("prices")).await;

    assert_eq!(rows[0][1], decimal(max));
    assert_eq!(rows[1][1], decimal(min));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn money_max_min_exact() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    money_round_trip(
        connection.as_ref(),
        "money",
        "922337203685477.5807",
        "-922337203685477.5808",
    )
    .await;
}

/// The editor and plain queries read MONEY without the decimal cast
/// browse uses, through the float tiberius makes of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn money_in_the_editor_and_queries_reads_exactly() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let sql = "SELECT CAST(123456789.1234 AS money), CAST(-214748.3648 AS smallmoney), \
               CAST(549755813887.9999 AS money), CAST(NULL AS money), CAST(922337203685477.5807 AS money)";

    let edited = run_ok(session.as_ref(), sql).await.rows().remove(0);
    let queried = rows(connection.as_ref(), sql).await.remove(0);

    for row in [edited, queried] {
        assert_eq!(row[0], decimal("123456789.1234"));
        assert_eq!(row[1], decimal("-214748.3648"));
        assert_eq!(row[2], decimal("549755813887.9999"));
        assert_eq!(row[3], Value::Null);
        assert!(matches!(&row[4], Value::Undecodable(_)), "{:?}", row[4]);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn smallmoney() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    money_round_trip(connection.as_ref(), "smallmoney", "214748.3647", "-214748.3648").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn datetimeoffset_plus_0530_round_trip_keeps_offset() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.events (at datetimeoffset(7) NULL)"],
    )
    .await;
    let table = dbo("events");
    let column = columns(connection.as_ref(), &table).await.remove(0);
    let local = DateTime::parse_from_rfc3339("2024-06-15T13:45:30.1234567+05:30").expect("a timestamp");
    let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(local)));

    let dialect = connection.dialect();
    write(
        connection.as_ref(),
        vec![insert_one(dialect.as_ref(), &table, &column, value.clone())],
    )
    .await
    .expect("the insert");

    assert_eq!(browse(connection.as_ref(), &table).await, vec![vec![value]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn varbinary_typed_null_insert() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.blobs (data varbinary(max) NULL)"],
    )
    .await;
    let table = dbo("blobs");
    let column = columns(connection.as_ref(), &table).await.remove(0);

    let dialect = connection.dialect();
    write(
        connection.as_ref(),
        vec![insert_one(dialect.as_ref(), &table, &column, Value::Null)],
    )
    .await
    .expect("a NULL typed as varbinary converts");

    assert_eq!(browse(connection.as_ref(), &table).await, vec![vec![Value::Null]]);
}
