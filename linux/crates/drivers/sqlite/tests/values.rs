use drivers_sqlite::SqliteDriver;
use tablepro_core::value::Temporal;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

async fn open() -> Result<Box<dyn tablepro_core::Connection>, tablepro_core::DriverError> {
    let opts = ConnectOptions {
        database: ":memory:".into(),
        ..Default::default()
    };
    SqliteDriver.connect(opts).await
}

#[tokio::test]
async fn a_value_keeps_the_storage_class_it_was_written_with() {
    let conn = open().await.expect("an in-memory database");
    conn.execute("CREATE TABLE loose (id integer primary key, anything integer)")
        .await
        .expect("the table");
    conn.execute(
        "INSERT INTO loose (id, anything) VALUES (1, 42), (2, 'text in an integer column'),
         (3, 1.5), (4, x'deadbeef'), (5, NULL)",
    )
    .await
    .expect("the rows");

    let q = conn
        .query("SELECT anything FROM loose ORDER BY id")
        .await
        .expect("the rows read back");

    assert_eq!(q.rows[0][0], Value::Int(42));
    // SQLite lets a column hold any storage class, so text in an
    // integer column reads as the text it holds, not as a null.
    assert_eq!(q.rows[1][0], Value::Text("text in an integer column".into()));
    assert_eq!(q.rows[2][0], Value::Float64(1.5));
    assert_eq!(q.rows[3][0], Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]));
    assert_eq!(q.rows[4][0], Value::Null);
}

#[tokio::test]
async fn a_declared_type_reads_the_value_it_names() {
    let conn = open().await.expect("an in-memory database");
    conn.execute(
        "CREATE TABLE typed (
            id integer primary key,
            flag boolean,
            day date,
            moment datetime,
            written date
        )",
    )
    .await
    .expect("the table");
    conn.execute(
        "INSERT INTO typed (id, flag, day, moment, written)
         VALUES (1, 1, '2024-06-15', '2024-06-15 13:45:30', 'not a date at all')",
    )
    .await
    .expect("the row");

    let q = conn
        .query("SELECT flag, day, moment, written FROM typed")
        .await
        .expect("the row read back");
    let row = &q.rows[0];

    assert_eq!(row[0], Value::Bool(true));
    let day = chrono::NaiveDate::from_ymd_opt(2024, 6, 15).expect("a date");
    assert_eq!(row[1], Value::Date(Temporal::Finite(day)));
    let moment = day.and_hms_opt(13, 45, 30).expect("a timestamp");
    assert_eq!(row[2], Value::Timestamp(Temporal::Finite(moment)));
    // A date column holding text that is not a date keeps the text.
    assert_eq!(row[3], Value::Text("not a date at all".into()));
}
