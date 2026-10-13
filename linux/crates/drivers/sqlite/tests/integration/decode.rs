//! Values come back as the storage class SQLite holds, whatever the
//! column says, and go back the same way.

use tablepro_core::column::{ColumnKind, FloatWidth, IntegerKind, IntegerWidth};
use tablepro_core::meta::TableRef;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::{RowLimit, Value};

use crate::support::{TestFile, apply, call, query, statement};

fn integer() -> ColumnKind {
    ColumnKind::Integer(IntegerKind {
        width: IntegerWidth::W64,
        signed: true,
    })
}

#[tokio::test]
async fn count_sum_and_expression_columns_are_typed() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE t (x REAL, n INTEGER)",
            "INSERT INTO t VALUES (1.5, 2), (2.5, 3)",
        ],
    )
    .await
    .unwrap();

    let result = query(
        connection.as_ref(),
        "SELECT count(*) AS c, sum(x) AS s, n + 1 AS next, 'a' || 'b' AS joined FROM t",
    )
    .await;

    assert_eq!(
        result.rows[0],
        [
            Value::Int(2),
            Value::Float64(4.0),
            Value::Int(3),
            Value::Text("ab".to_owned())
        ]
    );
    let kinds: Vec<&ColumnKind> = result.columns.iter().map(|column| &column.column_type.kind).collect();
    assert_eq!(kinds[0], &integer());
    assert_eq!(kinds[1], &ColumnKind::Float(FloatWidth::F64));
    assert_eq!(kinds[2], &integer());
    assert!(matches!(kinds[3], ColumnKind::Text { .. }), "{:?}", kinds[3]);
    connection.close().await.unwrap();
}

#[tokio::test]
async fn decimal_declared_column_decodes_storage_class() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE prices (id INTEGER PRIMARY KEY, amount DECIMAL(10,2))",
            "INSERT INTO prices (amount) VALUES (12), (1.25), ('n/a'), (x'00ff'), (NULL), ('007')",
        ],
    )
    .await
    .unwrap();

    let result = query(connection.as_ref(), "SELECT amount FROM prices ORDER BY id").await;

    let amounts: Vec<Value> = result.rows.into_iter().map(|mut row| row.remove(0)).collect();
    assert_eq!(
        amounts,
        [
            Value::Int(12),
            Value::Float64(1.25),
            Value::Text("n/a".to_owned()),
            Value::Bytes(vec![0x00, 0xff]),
            Value::Null,
            // Numeric affinity turns text that reads as a number into one.
            Value::Int(7),
        ]
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn strict_table_round_trip() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE fixed (id INTEGER PRIMARY KEY, n INTEGER, r REAL, t TEXT, b BLOB) STRICT",
            "INSERT INTO fixed VALUES (1, 9223372036854775807, 0.1, 'é', x'00')",
        ],
    )
    .await
    .unwrap();
    let table = TableRef::unqualified("fixed");
    let columns = connection.fetch_columns(&table, call()).await.unwrap();
    let identity = connection.row_identity(&table, call()).await.unwrap();
    let read = query(connection.as_ref(), "SELECT id, n, r, t, b FROM fixed").await;
    let row = read.rows[0].clone();

    let changes = ChangeSet {
        changes: vec![RowChange::Update(RowUpdate {
            key: vec![row[0].clone()],
            assignments: vec![
                (1, Value::Int(i64::MIN)),
                (2, Value::Float64(-0.25)),
                (3, Value::Text("ü'".to_owned())),
                (4, Value::Bytes(vec![1, 2, 3])),
            ],
        })],
    };
    let dialect = connection.dialect();
    let plan = plan_save(dialect.as_ref(), &table, &columns, &identity, &changes).unwrap();
    connection.write_batch(&plan.batch, call()).await.unwrap();
    let after = connection
        .query_bound(
            &statement("SELECT n, r, t, b FROM fixed"),
            RowLimit::EDITOR_DEFAULT,
            call(),
        )
        .await
        .unwrap();

    assert_eq!(
        row[1..],
        [
            Value::Int(i64::MAX),
            Value::Float64(0.1),
            Value::Text("é".to_owned()),
            Value::Bytes(vec![0])
        ]
    );
    assert_eq!(
        after.rows[0],
        [
            Value::Int(i64::MIN),
            Value::Float64(-0.25),
            Value::Text("ü'".to_owned()),
            Value::Bytes(vec![1, 2, 3])
        ]
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn a_date_column_keeps_the_spelling_it_was_written_with() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE stamps (id INTEGER PRIMARY KEY, at DATETIME, note TEXT)",
            "INSERT INTO stamps (at, note) VALUES ('2024-06-15T13:45:30Z', 'a')",
        ],
    )
    .await
    .unwrap();
    let table = TableRef::unqualified("stamps");
    let columns = connection.fetch_columns(&table, call()).await.unwrap();
    let read = query(connection.as_ref(), "SELECT at FROM stamps").await;
    let at = read.rows[0][0].clone();

    // The value names its own row, so a save keyed by it must match the
    // row as stored, T and Z included.
    let changes = ChangeSet {
        changes: vec![RowChange::Delete {
            key: vec![Value::Int(1)],
        }],
    };
    let identity = connection.row_identity(&table, call()).await.unwrap();
    let dialect = connection.dialect();
    let plan = plan_save(dialect.as_ref(), &table, &columns, &identity, &changes).unwrap();
    let report = connection.write_batch(&plan.batch, call()).await.unwrap();

    assert_eq!(at, Value::Text("2024-06-15T13:45:30Z".to_owned()));
    assert!(matches!(columns[1].column_type.kind, ColumnKind::Timestamp { .. }));
    assert_eq!(report.rows_affected, [Some(1)]);
    connection.close().await.unwrap();
}
