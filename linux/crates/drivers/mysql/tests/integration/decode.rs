//! Every value as the server sent it, in both protocols: the binary one
//! the grid reads through and the text one the editor runs over.

use std::sync::Arc;

use tablepro_core::column::{BoolStorage, ColumnKind, FloatWidth, TemporalZone};
use tablepro_core::save::{ChangeSet, RowUpdate, plan_save};
use tablepro_core::value::Temporal;
use tablepro_core::{Connection, Value};

use crate::support::{CALL, FLAVOURS, connect, rows, run_ok, session, setup, start, table, text, within};

/// The same SELECT through `query_bound` (binary) and an editor run
/// (text).
async fn both_protocols(connection: &Arc<dyn Connection>, sql: &str) -> (Vec<Value>, Vec<Value>) {
    let binary = rows(connection.as_ref(), sql).await.remove(0);
    let editor = session(connection.as_ref()).await;
    let text = run_ok(editor.as_ref(), sql).await.rows().remove(0);
    editor.close().await;
    (binary, text)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn unsigned_max_values_decode_in_both_protocols() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE maxima (a TINYINT UNSIGNED, b SMALLINT UNSIGNED, c MEDIUMINT UNSIGNED, \
                 d INT UNSIGNED, e BIGINT UNSIGNED)",
                "INSERT INTO maxima VALUES (255, 65535, 16777215, 4294967295, 18446744073709551615)",
            ],
        )
        .await;

        let (binary, text) = both_protocols(&connection, "SELECT a, b, c, d, e FROM maxima").await;

        let expected = vec![
            Value::Int(255),
            Value::Int(65_535),
            Value::Int(16_777_215),
            Value::Int(4_294_967_295),
            Value::UInt(u64::MAX),
        ];
        assert_eq!(binary, expected, "{flavour:?} binary");
        assert_eq!(text, expected, "{flavour:?} text");
        connection.close().await.expect("a close");
    }
}

/// An edit keyed by an unsigned id at its maximum binds, matches and
/// changes exactly that row.
async fn edit_by_max_id(connection: &Arc<dyn Connection>, id_type: &str, id: Value) {
    let name = "keyed";
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {name} (id {id_type} PRIMARY KEY, label varchar(20) NOT NULL)"
        )],
    )
    .await;
    let literal = text(&id);
    setup(
        connection.as_ref(),
        &[&format!(
            "INSERT INTO {name} VALUES ({literal}, 'before'), (1, 'other')"
        )],
    )
    .await;
    let target = table(name);
    let columns = connection
        .fetch_columns(&target, within(CALL))
        .await
        .expect("the columns");
    let identity = connection
        .row_identity(&target, within(CALL))
        .await
        .expect("the identity");
    let read = rows(
        connection.as_ref(),
        &format!("SELECT id FROM {name} WHERE label = 'before'"),
    )
    .await;
    assert_eq!(read[0][0], id, "the browsed id");
    let label = columns
        .iter()
        .position(|column| column.name == "label")
        .expect("a label column");
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![read[0][0].clone()],
            assignments: vec![(label, Value::Text("after".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    let dialect = connection.dialect();
    let plan = plan_save(dialect.as_ref(), &target, &columns, &identity, &changes).expect("a plan");

    let report = connection
        .write_batch(&plan.batch, within(CALL))
        .await
        .expect("the edit");

    assert_eq!(report.rows_affected, [Some(1)]);
    let after = rows(
        connection.as_ref(),
        &format!("SELECT id, label FROM {name} ORDER BY label"),
    )
    .await;
    assert_eq!(after[0], [id, Value::Text("after".to_owned())]);
    assert_eq!(after[1][1], Value::Text("other".to_owned()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn int_unsigned_max_id_row_edits_through_plan_save() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        edit_by_max_id(&connection, "INT UNSIGNED", Value::Int(4_294_967_295)).await;
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn bigint_unsigned_max_id_edit_affects_one_row() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        edit_by_max_id(&connection, "BIGINT UNSIGNED", Value::UInt(u64::MAX)).await;
        connection.close().await.expect("a close");
    }
}

/// A `_bin` collation makes MySQL flag the column BINARY, which sqlx
/// names VARBINARY; the charset is what decides, so it is still text.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn bin_collation_text_decodes_as_text() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE collated (a varchar(10) COLLATE utf8mb4_bin, b text COLLATE utf8mb4_bin, c varbinary(4))",
                "INSERT INTO collated VALUES ('Alpha', 'Beta', 0x00ff)",
            ],
        )
        .await;

        let (binary, text) = both_protocols(&connection, "SELECT a, b, c FROM collated").await;

        let expected = vec![
            Value::Text("Alpha".to_owned()),
            Value::Text("Beta".to_owned()),
            Value::Bytes(vec![0x00, 0xff]),
        ];
        assert_eq!(binary, expected, "{flavour:?} binary");
        assert_eq!(text, expected, "{flavour:?} text");
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn wire_only_types_read_back() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE wire (d DECIMAL(65,30), b BIT(10), y YEAR, g GEOMETRY, t TIME, f tinyint(1))",
                "INSERT INTO wire VALUES ('12345678901234567890123456789012345.123456789012345678901234567890', \
                 b'1010101010', 2024, ST_GeomFromText('POINT(1 2)'), '-838:59:59', 2)",
            ],
        )
        .await;

        let (binary, text) = both_protocols(&connection, "SELECT d, b, y, g, t, f FROM wire").await;

        for (protocol, values) in [("binary", &binary), ("text", &text)] {
            assert_eq!(
                tablepro_core::export::value_to_text(&values[0]).as_deref(),
                Some("12345678901234567890123456789012345.123456789012345678901234567890"),
                "{flavour:?} {protocol}"
            );
            assert!(
                matches!(&values[1], Value::Bits(bits) if bits.to_u64() == Some(0b10_1010_1010)),
                "{flavour:?} {protocol}: {:?}",
                values[1]
            );
            assert_eq!(values[2], Value::Int(2024), "{flavour:?} {protocol}");
            assert!(
                matches!(&values[3], Value::Bytes(bytes) if bytes.len() == 25),
                "{flavour:?} {protocol}"
            );
            assert!(
                matches!(&values[4], Value::Time(time) if time.format(None) == "-838:59:59"),
                "{flavour:?} {protocol}: {:?}",
                values[4]
            );
            assert_eq!(values[5], Value::Int(2), "{flavour:?} {protocol}: tinyint(1) keeps 2");
        }
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn zero_date_is_other() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(connection.as_ref(), &["CREATE TABLE zero (d date, s datetime)"]).await;
        let editor = session(connection.as_ref()).await;
        run_ok(
            editor.as_ref(),
            "SET SESSION sql_mode = ''; INSERT INTO zero VALUES ('0000-00-00', '0000-00-00 00:00:00')",
        )
        .await;
        editor.close().await;

        let (binary, text) = both_protocols(&connection, "SELECT d, s FROM zero").await;

        for (protocol, values) in [("binary", &binary), ("text", &text)] {
            assert!(
                matches!(&values[0], Value::Other(other) if other.text == "0000-00-00"),
                "{flavour:?} {protocol}: {:?}",
                values[0]
            );
            assert!(
                matches!(&values[1], Value::Other(other) if other.text == "0000-00-00 00:00:00"),
                "{flavour:?} {protocol}: {:?}",
                values[1]
            );
        }
        connection.close().await.expect("a close");
    }
}

/// Whether the catalogue's kind takes the decoded value as its own.
fn accepts(kind: &ColumnKind, value: &Value) -> bool {
    match (kind, value) {
        (_, Value::Null) => true,
        (ColumnKind::Bool(BoolStorage::Integer), Value::Int(_)) => true,
        (ColumnKind::Integer(integer), Value::Int(_)) => integer.signed || integer.width.bits() < 64,
        (ColumnKind::Integer(integer), Value::UInt(_)) => !integer.signed,
        (ColumnKind::Decimal { .. }, Value::Decimal(_)) => true,
        (ColumnKind::Float(FloatWidth::F32), Value::Float32(_)) => true,
        (ColumnKind::Float(FloatWidth::F64), Value::Float64(_)) => true,
        (ColumnKind::Text { .. } | ColumnKind::Enum { .. }, Value::Text(_)) => true,
        (ColumnKind::Bytes { .. } | ColumnKind::Spatial, Value::Bytes(_)) => true,
        (ColumnKind::Date, Value::Date(Temporal::Finite(_))) => true,
        (ColumnKind::Time { .. }, Value::Time(_)) => true,
        (
            ColumnKind::Timestamp {
                zone: TemporalZone::Naive,
                ..
            },
            Value::Timestamp(_),
        ) => true,
        (
            ColumnKind::Timestamp {
                zone: TemporalZone::Offset,
                ..
            },
            Value::TimestampTz(_),
        ) => true,
        (ColumnKind::Json { .. }, Value::Json(_)) => true,
        (ColumnKind::BitString { .. }, Value::Bits(_)) => true,
        (ColumnKind::Other, Value::Text(_) | Value::Other(_)) => true,
        _ => false,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn decoded_variants_match_catalog_kinds() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE every (b tinyint(1), i8 tinyint, u8 tinyint unsigned, i16 smallint, i24 mediumint, \
                 i32 int, u32 int unsigned zerofill, i64 bigint, u64 bigint unsigned, d decimal(10,2), \
                 f float, r double, c char(3), v varchar(10), bin varchar(10) COLLATE utf8mb4_bin, tx text, \
                 bl blob, vb varbinary(3), e enum('x','y'), s set('p','q'), dt date, tm time(3), \
                 ts datetime(6), st timestamp NULL, y year, bt bit(5), j json, g geometry)",
                "INSERT INTO every VALUES (1, -1, 200, -2, -3, -4, 5, -6, 7, 1.25, 1.5, 2.5, 'abc', 'v', 'B', \
                 'text', 0x01, 0x02, 'x', 'p,q', '2025-01-02', '-01:02:03.004', '2025-01-02 03:04:05.000006', \
                 '2025-01-02 03:04:05', 1999, b'10101', '{\"k\": 1}', ST_GeomFromText('POINT(0 0)'))",
            ],
        )
        .await;
        let columns = connection
            .fetch_columns(&table("every"), within(CALL))
            .await
            .expect("the columns");

        let values = rows(connection.as_ref(), "SELECT * FROM every").await.remove(0);

        assert_eq!(columns.len(), values.len());
        for (column, value) in columns.iter().zip(&values) {
            assert!(
                accepts(&column.column_type.kind, value),
                "{flavour:?}: {} is {:?} but read as {value:?}",
                column.name,
                column.column_type.kind
            );
        }
        connection.close().await.expect("a close");
    }
}
