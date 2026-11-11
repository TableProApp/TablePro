//! What only MongoDB does: its login database, the shell statements the
//! editor runs, the server's own error codes, and values of every BSON
//! type on their way to the grid and back.

use std::str::FromStr;

use secrecy::SecretString;
use tablepro_core::browse::SortKey;
use tablepro_core::browse::{PageRead, PageRequest, read_page};
use tablepro_core::column::ColumnKind;
use tablepro_core::edit::{CellInput, EditContext, parse_edit_text};
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::{ObjectKind, ObjectScope, PagePosition, RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::value::{JsonText, OtherValue, SqlDecimal, Temporal};
use tablepro_core::{
    ColumnInfo, Connection, Credentials, DatabaseDriver, DriverError, ErrorCategory, ResultEvent, RowLimit, RunEnd,
    RunOptions, ServerCode, Truncation, Value, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, DATABASE, column_names, connect, editor, fixture_options, options_over, rows, run, run_with, start, unique,
    within,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_wrong_password_is_refused_as_the_login() {
    let fixture = start().await;
    let mut options = fixture_options(&fixture, WorkspaceSettings::workspace(false));
    let tablepro_core::ConnectTarget::Network(target) = &mut options.target else {
        panic!("a network target");
    };
    target.credentials = Credentials::Password {
        username: "tablepro".to_owned(),
        password: SecretString::from("not-the-password".to_owned()),
    };

    let outcome = MongoDriver.connect(options, CancellationToken::new()).await;

    let error = outcome.err().expect("the login was refused");
    assert_eq!(error.category(), ErrorCategory::Authentication, "{error:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_user_defined_in_admin_logs_in_without_naming_it() {
    let fixture = start().await;
    let options = {
        let liveness = tablepro_test_support::conformance::test_liveness();
        let mut options = options_over(
            crate::support::direct(fixture.host(), fixture.port(), &liveness),
            crate::support::password(&fixture.password_credentials()),
            tablepro_core::TlsConfig::disabled(),
            WorkspaceSettings::workspace(false),
            liveness,
        );
        if let tablepro_core::ConnectTarget::Network(target) = &mut options.target {
            target.options = tablepro_core::NetworkOptions::default();
            target.database = None;
        }
        options
    };

    let connection = MongoDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("the user in admin logged in");

    connection.probe(within(CALL)).await.expect("the server answers");
    assert!(connection.server_info().major >= 7, "{:?}", connection.server_info());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_find_reads_the_fields_it_projects_in_the_order_it_sorts() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("find");
    let (filled, _) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').insertMany([{{_id: 1, label: 'one', size: 10}}, \
             {{_id: 2, label: 'two', size: 20}}, {{_id: 3, label: 'three', size: 30}}])"
        ),
    )
    .await;
    assert_eq!(filled.end, RunEnd::Completed);

    let (read, events) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').find({{size: {{$gte: 20}}}}, {{label: 1}}).sort({{_id: -1}})"),
    )
    .await;

    assert_eq!(read.end, RunEnd::Completed);
    assert_eq!(column_names(&events), ["_id", "label"]);
    assert_eq!(
        rows(&events),
        [
            vec![Value::Int32(3), Value::Text("three".to_owned())],
            vec![Value::Int32(2), Value::Text("two".to_owned())],
        ]
    );

    let (counted, events) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').countDocuments({{size: {{$lt: 25}}}})"),
    )
    .await;
    assert_eq!(counted.end, RunEnd::Completed);
    assert_eq!(rows(&events), [vec![Value::Int(2)]]);

    let (iterated, events) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').aggregate([{{$match: {{size: {{$gt: 10}}}}}}]).itcount()"),
    )
    .await;
    assert_eq!(iterated.end, RunEnd::Completed);
    assert_eq!(rows(&events), [vec![Value::Int(2)]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn use_switches_the_database_the_next_statements_run_in() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let database = unique("db");
    let collection = unique("used");

    let (switched, _) = run(
        session.as_ref(),
        &format!("use {database}\ndb.getCollection('{collection}').insertOne({{_id: 1}})"),
    )
    .await;
    assert_eq!(switched.end, RunEnd::Completed);
    let (listed, events) = run(session.as_ref(), "db.getCollectionNames()").await;

    assert_eq!(listed.end, RunEnd::Completed);
    assert_eq!(rows(&events), [vec![Value::Text(collection.clone())]]);
    let objects = connection
        .list_objects(&ObjectScope::Schema(database.clone()), within(CALL))
        .await
        .expect("the database's collections");
    assert!(
        objects
            .iter()
            .any(|object| object.name == collection && object.kind == ObjectKind::Table),
        "{objects:?}"
    );
    let defaults = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the connection's own collections");
    assert!(
        defaults.iter().all(|object| object.name != collection),
        "the connection's database moved with the editor's: {defaults:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_duplicate_key_reports_the_server_code() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let insert = format!("db.getCollection('{}').insertOne({{_id: 1}})", unique("duplicate"));
    let (first, _) = run(session.as_ref(), &insert).await;
    assert_eq!(first.end, RunEnd::Completed);

    let (second, _) = run(session.as_ref(), &insert).await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &second.end else {
        panic!("the second insert gave {:?}", second.end);
    };
    assert!(
        matches!(diagnostics.code, Some(ServerCode::Mongo { code: 11000, .. })),
        "{diagnostics:?}"
    );
    let (after, _) = run(session.as_ref(), "db.runCommand({ping: 1})").await;
    assert_eq!(after.end, RunEnd::Completed, "the session runs again");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_statement_that_does_not_parse_is_refused_with_where_it_fails() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let text = "db.getCollection('items').find({size: })";

    let (summary, _) = run(session.as_ref(), text).await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("the statement gave {:?}", summary.end);
    };
    assert!(diagnostics.message.starts_with("SyntaxError: "), "{diagnostics:?}");
    let position = diagnostics.position.expect("a position") as usize;
    assert_eq!(text.chars().nth(position - 1), Some('}'), "{diagnostics:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_view_is_listed_as_one_and_has_no_key_to_edit_by() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("source");
    let view = unique("view");
    let (created, _) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').insertOne({{_id: 1, size: 4}})\n\
             db.createView('{view}', '{collection}', [{{$match: {{size: {{$gt: 1}}}}}}])"
        ),
    )
    .await;
    assert_eq!(created.end, RunEnd::Completed);

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the collections");
    let table = TableRef::new(Some(DATABASE.to_owned()), view.clone());
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");

    assert!(
        objects
            .iter()
            .any(|object| object.name == view && object.kind == ObjectKind::View),
        "{objects:?}"
    );
    assert_eq!(identity, RowIdentity::Unordered);
    let read = page(connection.as_ref(), &table).await;
    assert_eq!(read.result.rows.len(), 1);
}

/// One document with a field of each BSON type the grid shows plainly,
/// and the types it shows as extended JSON.
const EVERY_TYPE: &str = "{_id: 1, oid: ObjectId('5f1d7a0c9b1e8b2a3c4d5e6f'), \
    at: ISODate('2024-05-06T07:08:09.010Z'), price: NumberDecimal('12.50'), big: NumberLong('9007199254740993'), \
    ratio: 0.5, flag: true, nothing: null, nested: {a: [1, 2]}, \
    uid: UUID('0e3f6f0e-8a3b-4b8e-9a7c-2f1d1b3c4d5e'), blob: BinData(0, 'AAEC'), \
    stamp: Timestamp({t: 1700000000, i: 3})}";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn values_reach_the_grid_as_their_own_types() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("types");
    let (inserted, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertOne({EVERY_TYPE})"),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);

    let (read, events) = run(session.as_ref(), &format!("db.getCollection('{collection}').find()")).await;

    assert_eq!(read.end, RunEnd::Completed);
    assert_eq!(
        column_names(&events),
        [
            "_id", "oid", "at", "price", "big", "ratio", "flag", "nothing", "nested", "uid", "blob", "stamp"
        ]
    );
    let row = rows(&events).pop().expect("the document");
    let at = chrono::DateTime::parse_from_rfc3339("2024-05-06T07:08:09.010Z").expect("a time");
    assert_eq!(row[0], Value::Int32(1));
    assert_eq!(
        row[1],
        Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
        }))
    );
    assert_eq!(
        row[2],
        Value::TimestampTz(Temporal::Finite(tablepro_core::value::OffsetTimestamp::from_datetime(
            at
        )))
    );
    assert_eq!(
        row[3],
        Value::Decimal(SqlDecimal::from_str("12.50").expect("a decimal"))
    );
    assert_eq!(row[4], Value::Int(9_007_199_254_740_993));
    assert_eq!(row[5], Value::Float64(0.5));
    assert_eq!(row[6], Value::Bool(true));
    assert_eq!(row[7], Value::Null);
    assert_json(&row[8], r#"{"a": [1, 2]}"#);
    assert_eq!(
        row[9],
        Value::Uuid(uuid::Uuid::parse_str("0e3f6f0e-8a3b-4b8e-9a7c-2f1d1b3c4d5e").expect("a UUID"))
    );
    assert_eq!(row[10], Value::Bytes(vec![0, 1, 2]));
    assert_json(&row[11], r#"{"$timestamp": {"t": 1700000000, "i": 3}}"#);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_nested_field_edited_as_json_keeps_its_types() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("nested");
    let (inserted, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertOne({EVERY_TYPE})"),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the fields");
    let nested = columns
        .iter()
        .position(|column| column.name == "nested")
        .expect("the nested field");
    let edited = r#"{"a": [3], "b": {"$numberLong": "4"}, "at": {"$date": "2020-01-02T03:04:05Z"}}"#;

    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");
    let plan = plan_save(
        &*connection.dialect(),
        &table,
        &columns,
        &identity,
        &ChangeSet {
            changes: vec![RowChange::Update(RowUpdate {
                key: vec![Value::Int32(1)],
                assignments: vec![(
                    nested,
                    CellInput::Value(Value::Json(JsonText::parse(edited.to_owned()).expect("JSON"))),
                )],
                read: Vec::new(),
            })],
        },
    )
    .expect("a save plan");
    let report = connection
        .write_batch(&plan.batch, within(CALL))
        .await
        .expect("the save");

    assert_eq!(report.rows_affected, [Some(1)]);
    let read = page(connection.as_ref(), &table).await;
    let row = read.result.rows.first().expect("the document");
    assert_json(
        &row[nested],
        r#"{"a": [3], "b": {"$numberLong": "4"}, "at": {"$date": "2020-01-02T03:04:05.000Z"}}"#,
    );
    let (typed, events) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').countDocuments({{'nested.b': {{$type: 'long'}}, \
             'nested.at': {{$type: 'date'}}, 'nested.a.0': {{$type: 'int'}}}})"
        ),
    )
    .await;
    assert_eq!(typed.end, RunEnd::Completed);
    assert_eq!(rows(&events), [vec![Value::Int(1)]], "the edit kept the BSON types");
}

// Each edit carries the value its cell was read as, as a table tab's save does.
fn number_edits<const N: usize>(
    rows: &[Vec<Value>],
    columns: &[ColumnInfo],
    edits: [(i32, [(usize, &str); 2]); N],
) -> Vec<RowChange> {
    edits
        .into_iter()
        .map(|(id, cells)| {
            let row = rows
                .iter()
                .find(|row| row.first() == Some(&Value::Int32(id)))
                .expect("the document");
            let mut assignments = Vec::new();
            let mut read = Vec::new();
            for (column, text) in cells {
                let edited = parse_edit_text(text, &columns[column], EditContext::UpdateRow, Some(&row[column]))
                    .expect("a number");
                assignments.push((column, edited));
                read.push((column, row[column].clone()));
            }
            RowChange::Update(RowUpdate {
                key: vec![row[0].clone()],
                assignments,
                read,
            })
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_edited_number_keeps_its_own_bson_type() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("widths");
    // The census reads the first 1,000 documents, so the int32 values after them sit in a long and a double column.
    let sampled: Vec<String> = (1..=1_000)
        .map(|id| format!("{{_id: {id}, qty: NumberLong({id}), price: {id}.5}}"))
        .collect();
    let past = "{_id: 1001, qty: NumberInt(3), price: 7}, {_id: 1002, qty: NumberInt(5), price: 9}";
    let (inserted, _) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').insertMany([{}, {past}])",
            sampled.join(", ")
        ),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the fields");
    let types: Vec<&str> = columns.iter().map(|column| column.column_type.name.as_str()).collect();
    assert_eq!(types, ["int", "long", "double"], "the census saw one type per field");
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");
    let request = PageRequest {
        table: &table,
        columns: &columns,
        filter: &FilterSet::default(),
        sort: &[SortKey {
            column: 0,
            ascending: false,
        }],
        identity: &identity,
        position: &PagePosition::First,
        limit: 3,
    };
    let read = read_page::<Box<dyn std::error::Error + Send + Sync>>(connection.as_ref(), &request, &within(CALL))
        .await
        .expect("a page");
    let changes = number_edits(
        &read.result.rows,
        &columns,
        [
            (1002, [(1, "3000000000"), (2, "9.5")]),
            (1001, [(1, "4"), (2, "8")]),
            (1000, [(1, "6"), (2, "2.5")]),
        ],
    );
    let plan = plan_save(
        &*connection.dialect(),
        &table,
        &columns,
        &identity,
        &ChangeSet { changes },
    )
    .expect("a save plan");
    let report = connection
        .write_batch(&plan.batch, within(CALL))
        .await
        .expect("the save");
    assert_eq!(report.rows_affected, [Some(1), Some(1), Some(1)]);

    for (conditions, why) in [
        (
            "{_id: 1001}, {qty: 4}, {qty: {$type: 'int'}}, {price: 8}, {price: {$type: 'int'}}",
            "an int32 past the census took its column's type",
        ),
        (
            "{_id: 1000}, {qty: 6}, {qty: {$type: 'long'}}, {price: 2.5}, {price: {$type: 'double'}}",
            "a number of its column's own type changed type",
        ),
        (
            "{_id: 1002}, {qty: NumberLong('3000000000')}, {qty: {$type: 'long'}}, {price: 9.5}, \
             {price: {$type: 'double'}}",
            "an int32 edited past its range did not take the column's type",
        ),
    ] {
        let (typed, events) = run(
            session.as_ref(),
            &format!("db.getCollection('{collection}').countDocuments({{$and: [{conditions}]}})"),
        )
        .await;
        assert_eq!(typed.end, RunEnd::Completed);
        assert_eq!(rows(&events), [vec![Value::Int(1)]], "{why}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_result_set_event_names_the_fields_a_later_document_brings() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("ragged");
    let (inserted, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertMany([{{_id: 1, a: 1}}, {{_id: 2, b: 2}}])"),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);

    let (read, events) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').find().sort({{_id: 1}})"),
    )
    .await;

    assert_eq!(read.end, RunEnd::Completed);
    assert_eq!(column_names(&events), ["_id", "a", "b"]);
    assert!(
        events
            .iter()
            .any(|event| matches!(event, ResultEvent::ResultSetStarted { .. })),
        "{events:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_field_of_two_number_types_is_json_and_an_edit_keeps_its_type() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("quantities");
    let (inserted, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertMany([{{_id: 1, qty: 3}}, {{_id: 2, qty: NumberLong(7)}}])"),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the fields");
    let qty = columns
        .iter()
        .position(|column| column.name == "qty")
        .expect("the qty field");
    assert!(
        matches!(columns[qty].column_type.kind, ColumnKind::Json { .. }),
        "an int and a long: {:?}",
        columns[qty]
    );
    let read = page_with(connection.as_ref(), &table, &columns).await;
    assert_json(&read.result.rows[0][qty], "3");
    assert_json(&read.result.rows[1][qty], r#"{"$numberLong": "7"}"#);
    let identity = connection
        .row_identity(&table, within(CALL))
        .await
        .expect("an identity");

    let plan = plan_save(
        &*connection.dialect(),
        &table,
        &columns,
        &identity,
        &ChangeSet {
            changes: vec![RowChange::Update(RowUpdate {
                key: vec![Value::Int(1)],
                assignments: vec![(
                    qty,
                    CellInput::Value(Value::Json(JsonText::parse("4".to_owned()).expect("JSON"))),
                )],
                read: Vec::new(),
            })],
        },
    )
    .expect("a save plan");
    let report = connection
        .write_batch(&plan.batch, within(CALL))
        .await
        .expect("the save");

    assert_eq!(report.rows_affected, [Some(1)]);
    let (typed, events) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').countDocuments({{_id: 1, qty: {{$eq: 4, $type: 'int'}}}})\n\
             db.getCollection('{collection}').countDocuments({{_id: 2, qty: {{$type: 'long'}}}})"
        ),
    )
    .await;
    assert_eq!(typed.end, RunEnd::Completed);
    assert_eq!(
        rows(&events),
        [vec![Value::Int(1)], vec![Value::Int(1)]],
        "the edit kept the int and left the long a long"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_connection_that_never_read_the_fields_shows_json_fields_as_json() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("reconnected");
    let (inserted, _) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').insertMany([{{_id: 1, n: 'five'}}, {{_id: 2, n: NumberLong(5)}}])"),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the fields");
    let n = columns
        .iter()
        .position(|column| column.name == "n")
        .expect("the n field");
    // As after a reconnect: the tab keeps its columns and pages on a
    // connection that has not read them.
    let reconnected = connect(&fixture).await;

    let read = page_with(reconnected.as_ref(), &table, &columns).await;

    assert_json(&read.result.rows[0][n], r#""five""#);
    assert_json(&read.result.rows[1][n], r#"{"$numberLong": "5"}"#);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_projected_find_streams_its_rows_and_resolves_the_types_later_rows_bring() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let collection = unique("streamed");
    // Past the first batch of rows, `n` holds strings too.
    let documents: Vec<String> = (0..300)
        .map(|id| match id < 280 {
            true => format!("{{_id: {id}, n: {id}}}"),
            false => format!("{{_id: {id}, n: 'n{id}'}}"),
        })
        .collect();
    let (inserted, _) = run(
        session.as_ref(),
        &format!(
            "db.getCollection('{collection}').insertMany([{}])",
            documents.join(", ")
        ),
    )
    .await;
    assert_eq!(inserted.end, RunEnd::Completed);
    let find = format!("db.getCollection('{collection}').find({{}}, {{n: 1}}).sort({{_id: 1}})");

    let (read, events) = run(
        session.as_ref(),
        &format!("db.getCollection('{collection}').countDocuments({{}})\n{find}"),
    )
    .await;

    assert_eq!(read.end, RunEnd::Completed);
    let at = events
        .iter()
        .enumerate()
        .filter(|(_, event)| matches!(event, ResultEvent::ResultSetStarted { .. }))
        .nth(1)
        .map(|(index, _)| index)
        .expect("the find's result set");
    let [
        ResultEvent::ResultSetStarted { columns: started },
        ResultEvent::Rows(first),
        ResultEvent::Rows(rest),
        ResultEvent::ColumnsResolved {
            set_index,
            columns: resolved,
        },
        ResultEvent::ResultSetFinished {
            retained: 300,
            total_rows: Some(300),
            truncation: Truncation::Complete,
        },
    ] = &events[at..]
    else {
        panic!("the find sent {:?}", &events[at..]);
    };
    assert_eq!((first.len(), rest.len()), (256, 44));
    assert_eq!(*set_index, 1, "the count's result set came first");
    assert_eq!(started[1].column_type.name, "int");
    assert_eq!(resolved[1].column_type.name, "mixed");

    let limit = RowLimit::new(270).expect("a limit");
    let (cut, events) = run_with(
        session.as_ref(),
        &find,
        RunOptions::new(CancellationToken::new()).with_row_limit(limit),
    )
    .await;

    assert_eq!(cut.end, RunEnd::Completed);
    assert!(
        matches!(
            events.as_slice(),
            [
                ResultEvent::ResultSetStarted { .. },
                ResultEvent::Rows(first),
                ResultEvent::Rows(rest),
                ResultEvent::RowLimitReached { retained: 270 },
                ResultEvent::ResultSetFinished {
                    retained: 270,
                    total_rows: None,
                    truncation: Truncation::ReadPastLimit,
                },
            ] if first.len() == 256 && rest.len() == 14
        ),
        "{events:?}"
    );
}

/// A JSON cell that reads as `expected`, whatever its spacing.
fn assert_json(cell: &Value, expected: &str) {
    let read = match cell {
        Value::Json(json) => serde_json::from_str::<serde_json::Value>(json.as_str()).ok(),
        _ => None,
    };
    let expected = serde_json::from_str::<serde_json::Value>(expected).expect("JSON");
    assert_eq!(read.as_ref(), Some(&expected), "the cell is {cell:?}");
}

/// The first page of `table` as the grid reads it.
async fn page(connection: &dyn Connection, table: &TableRef) -> PageRead {
    let columns = connection.fetch_columns(table, within(CALL)).await.expect("the fields");
    page_with(connection, table, &columns).await
}

/// The first page of `table` under `columns`, which another connection
/// may have read.
async fn page_with(connection: &dyn Connection, table: &TableRef, columns: &[ColumnInfo]) -> PageRead {
    let identity = connection.row_identity(table, within(CALL)).await.expect("an identity");
    let request = PageRequest {
        table,
        columns,
        filter: &FilterSet::default(),
        sort: &[],
        identity: &identity,
        position: &PagePosition::First,
        limit: 100,
    };
    read_page::<Box<dyn std::error::Error + Send + Sync>>(connection, &request, &within(CALL))
        .await
        .expect("a page")
}
