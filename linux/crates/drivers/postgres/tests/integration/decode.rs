//! Values written through bound parameters and read back through a
//! browse page come back exactly as they went in.

use chrono::{DateTime, FixedOffset, NaiveDate};
use tablepro_core::browse::{PageRequest, build_page, split_page};
use tablepro_core::edit::CellInput;
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, RowInsert, RowUpdate, plan_save};
use tablepro_core::value::{
    BitString, JsonText, OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, TimeWithOffset,
};
use tablepro_core::{Connection, RowLimit, Value};

use crate::support::{CALL, connect, scalar, setup, start, text, within};

const MATRIX: &str = "CREATE TABLE matrix (
    id int PRIMARY KEY,
    i2 int2, i4 int4, i8 int8, f4 float4, f8 float8,
    num numeric(20, 5), num_any numeric, b bool,
    txt text, vc varchar(10), ch char(5), bytes bytea, u uuid,
    js json, jb jsonb,
    d date, ts timestamp(6), tstz timestamptz, tm time, ttz timetz, iv interval,
    bt bit(4), vb varbit(8), ip inet, mac macaddr
)";

fn other(type_name: &str, text: &str) -> Value {
    Value::Other(Box::new(OtherValue {
        type_name: type_name.to_owned(),
        text: text.to_owned(),
    }))
}

fn matrix_row() -> Vec<Value> {
    let stamp = NaiveDate::from_ymd_opt(2024, 2, 29)
        .and_then(|date| date.and_hms_micro_opt(13, 45, 30, 123_456))
        .expect("a timestamp");
    let instant = DateTime::parse_from_rfc3339("2024-06-15T06:00:00.5+00:00").expect("an instant");
    vec![
        Value::Int(1),
        Value::Int(-32_768),
        Value::Int(2_147_483_647),
        Value::Int(i64::MIN),
        Value::Float32(1.5),
        Value::Float64(-2.25e100),
        Value::Decimal("12345.67890".parse().expect("a decimal")),
        Value::Decimal(SqlDecimal::nan()),
        Value::Bool(true),
        Value::Text("naïve ✓ ' \\ text".to_owned()),
        Value::Text("short".to_owned()),
        Value::Text("ab   ".to_owned()),
        Value::Bytes(vec![0, 255, 1]),
        Value::Uuid(uuid::Uuid::from_u128(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef)),
        Value::Json(JsonText::parse(r#"{"b": 1, "a": [2]}"#.to_owned()).expect("json")),
        Value::Json(JsonText::parse(r#"{"a": 1}"#.to_owned()).expect("json")),
        Value::Date(Temporal::Infinity),
        Value::Timestamp(Temporal::Finite(stamp)),
        Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(instant))),
        Value::Time("24:00:00".parse::<SqlTime>().expect("a time")),
        Value::TimeTz(TimeWithOffset {
            time: "12:34:56".parse().expect("a time"),
            offset: FixedOffset::east_opt(7 * 3600).expect("an offset"),
        }),
        Value::Interval(SqlInterval {
            months: 14,
            days: -3,
            microseconds: 4_500_000,
        }),
        Value::Bits(BitString::from_u64(0b1010, 4)),
        Value::Bits(BitString::from_u64(0b101, 3)),
        other("inet", "10.0.0.1/8"),
        other("macaddr", "08:00:2b:01:02:03"),
    ]
}

async fn page(connection: &dyn Connection, table: &TableRef) -> Vec<Vec<Value>> {
    let columns = connection
        .fetch_columns(table, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(table, within(CALL))
        .await
        .expect("the identity");
    let dialect = connection.dialect();
    let filter = FilterSet::default();
    let spec = build_page(
        dialect.as_ref(),
        &PageRequest {
            table,
            columns: &columns,
            filter: &filter,
            sort: &[],
            identity: &identity,
            position: &PagePosition::First,
            limit: 100,
        },
    )
    .expect("a page query");
    let result = connection
        .query_bound(&spec.statement, RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("the page");
    split_page(result, &spec).expect("a page").rows
}

async fn save(connection: &dyn Connection, table: &TableRef, changes: &ChangeSet) {
    let columns = connection
        .fetch_columns(table, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(table, within(CALL))
        .await
        .expect("the identity");
    let dialect = connection.dialect();
    let plan = plan_save(dialect.as_ref(), table, &columns, &identity, changes).expect("a save plan");
    connection
        .write_batch(&plan.batch, within(CALL))
        .await
        .expect("the save");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn round_trip_matrix() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[MATRIX]).await;
    let table = TableRef::new(Some("public".to_owned()), "matrix");
    let written = matrix_row();
    let changes = ChangeSet {
        inserts: vec![RowInsert {
            cells: written.iter().cloned().map(CellInput::Value).collect(),
        }],
        ..ChangeSet::default()
    };

    save(connection.as_ref(), &table, &changes).await;
    let read = page(connection.as_ref(), &table).await;

    assert_eq!(read.len(), 1);
    let names = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
    for ((column, sent), got) in names.iter().zip(&written).zip(&read[0]) {
        assert_eq!(got, sent, "{} did not round-trip", column.name);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_empty_page_still_has_its_columns() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[MATRIX]).await;
    let table = TableRef::new(Some("public".to_owned()), "matrix");

    let read = page(connection.as_ref(), &table).await;

    assert!(read.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn set_null_saves_typed_null() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE t (id int PRIMARY KEY, u uuid, d date, n numeric, b bit(3))",
            "INSERT INTO t VALUES (1, gen_random_uuid(), now(), 1.5, B'101')",
        ],
    )
    .await;
    let table = TableRef::new(Some("public".to_owned()), "t");
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Int(1)],
            assignments: (1..=4).map(|column| (column, Value::Null)).collect(),
        }],
        ..ChangeSet::default()
    };

    save(connection.as_ref(), &table, &changes).await;
    let read = page(connection.as_ref(), &table).await;

    assert_eq!(read[0][1..], [Value::Null, Value::Null, Value::Null, Value::Null]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn char10_key_update_affects_one_row() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE c (code char(10) PRIMARY KEY, v text)",
            "INSERT INTO c VALUES ('ab', 'x'), ('abc', 'y')",
        ],
    )
    .await;
    let table = TableRef::new(Some("public".to_owned()), "c");
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("the identity");
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Text("ab".to_owned())],
            assignments: vec![(1, Value::Text("changed".to_owned()))],
        }],
        ..ChangeSet::default()
    };

    save(connection.as_ref(), &table, &changes).await;

    assert_eq!(
        identity,
        RowIdentity::UniqueKey {
            columns: vec!["code".to_owned()]
        }
    );
    assert_eq!(
        text(&scalar(connection.as_ref(), "SELECT v FROM c WHERE code = 'ab'").await),
        "changed"
    );
    assert_eq!(
        text(&scalar(connection.as_ref(), "SELECT v FROM c WHERE code = 'abc'").await),
        "y"
    );
}
