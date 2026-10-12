//! Values that only survive a round trip when every digit and byte is
//! kept: wide numbers, sub-second keys and keys that are not UTF-8.

use tablepro_core::save::{ChangeSet, RowUpdate};
use tablepro_core::value::{SqlDecimal, Temporal};
use tablepro_core::{Connection, Value};

use crate::support::{CALL, connect, count, planned, quoted, rows, setup, start, table, unique, within};

async fn edit(connection: &dyn Connection, name: &str, key: Vec<Value>, column: usize, value: Value) {
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key,
            assignments: vec![(column, value)],
        }],
        ..ChangeSet::default()
    };
    let batch = planned(connection, &table(name), &changes).await;
    connection
        .write_batch(&batch, within(CALL))
        .await
        .expect("the planned edit");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn datetime64_3_utc_sorting_key_edit_affects_exactly_one_row() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("stamps");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (ts DateTime64(3, 'UTC'), v String) ENGINE = MergeTree ORDER BY ts"),
            &format!(
                "INSERT INTO {qualified} VALUES ('2024-06-15 08:30:00.000', 'c'), \
                 ('2024-06-15 08:30:00.123', 'a'), ('2024-06-15 08:30:00.124', 'b')"
            ),
        ],
    )
    .await;

    let read = rows(
        connection.as_ref(),
        &format!("SELECT ts, v FROM {qualified} ORDER BY ts"),
    )
    .await;
    let key = read[1][0].clone();
    let expected = chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
        .and_then(|date| date.and_hms_milli_opt(8, 30, 0, 123))
        .expect("a timestamp");
    assert_eq!(key, Value::Timestamp(Temporal::Finite(expected)));
    edit(
        connection.as_ref(),
        &name,
        vec![key],
        1,
        Value::Text("changed".to_owned()),
    )
    .await;

    let changed = rows(
        connection.as_ref(),
        &format!("SELECT toString(ts) FROM {qualified} WHERE v = 'changed'"),
    )
    .await;
    assert_eq!(changed, vec![vec![Value::Text("2024-06-15 08:30:00.123".to_owned())]]);
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn decimal_76_20_exact() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("decimals");
    let qualified = quoted(&name);
    let widest = "12345678901234567890123456789012345678901234567890123456.12345678901234567890";
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32, d Decimal(76, 20)) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1, toDecimal256('{widest}', 20))"),
        ],
    )
    .await;

    let read = rows(connection.as_ref(), &format!("SELECT d FROM {qualified}")).await;
    assert_eq!(read[0][0], Value::Decimal(widest.parse().expect("a decimal")));

    let replacement: SqlDecimal = "-99999999999999999999999999999999999999999999999999999999.00000000000000000001"
        .parse()
        .expect("a decimal");
    edit(
        connection.as_ref(),
        &name,
        vec![Value::Int(1)],
        1,
        Value::Decimal(replacement.clone()),
    )
    .await;

    let read = rows(connection.as_ref(), &format!("SELECT d FROM {qualified}")).await;
    assert_eq!(read[0][0], Value::Decimal(replacement));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn uint64_max_int256_float32_nan() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("wide");
    let qualified = quoted(&name);
    let lowest = "-57896044618658097711785492504343953926634992332820282019728792003956564819968";
    setup(
        connection.as_ref(),
        &[
            &format!(
                "CREATE TABLE {qualified} (id Int32, u UInt64, w Int256, f Float32) ENGINE = MergeTree ORDER BY id"
            ),
            &format!("INSERT INTO {qualified} VALUES (1, 18446744073709551615, {lowest}, nan)"),
        ],
    )
    .await;

    let read = rows(connection.as_ref(), &format!("SELECT u, w, f FROM {qualified}")).await;
    assert_eq!(read[0][0], Value::UInt(u64::MAX));
    assert_eq!(read[0][1], Value::WideInt(lowest.parse().expect("an Int256")));
    assert!(
        matches!(read[0][2], Value::Float32(nan) if nan.is_nan()),
        "{:?}",
        read[0][2]
    );

    edit(
        connection.as_ref(),
        &name,
        vec![Value::Int(1)],
        1,
        Value::UInt(u64::MAX - 1),
    )
    .await;
    edit(
        connection.as_ref(),
        &name,
        vec![Value::Int(1)],
        3,
        Value::Float32(f32::INFINITY),
    )
    .await;

    let read = rows(connection.as_ref(), &format!("SELECT u, f FROM {qualified}")).await;
    assert_eq!(read[0][0], Value::UInt(u64::MAX - 1));
    assert_eq!(read[0][1], Value::Float32(f32::INFINITY));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn invalid_utf8_string_key_row_editable_via_unhex() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("bytes");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (k String, v String) ENGINE = MergeTree ORDER BY k"),
            &format!("INSERT INTO {qualified} VALUES (unhex('ff41'), 'old'), ('A', 'other')"),
        ],
    )
    .await;

    let read = rows(connection.as_ref(), &format!("SELECT k, v FROM {qualified} ORDER BY k")).await;
    let key = read
        .iter()
        .map(|row| row[0].clone())
        .find(|key| matches!(key, Value::Bytes(_)))
        .expect("the key that is not UTF-8");
    assert_eq!(key, Value::Bytes(vec![0xff, 0x41]));
    edit(connection.as_ref(), &name, vec![key], 1, Value::Text("new".to_owned())).await;

    let edited = count(
        connection.as_ref(),
        &format!("SELECT count() FROM {qualified} WHERE k = unhex('ff41') AND v = 'new'"),
    )
    .await;
    let untouched = count(
        connection.as_ref(),
        &format!("SELECT count() FROM {qualified} WHERE k = 'A' AND v = 'other'"),
    )
    .await;
    assert_eq!((edited, untouched), (1, 1));
    connection.close().await.expect("a close");
}
