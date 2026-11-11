//! A table export as the export dialog's Entire Table reads it: the
//! statement `build_export` writes for every field, then `stream_read`.

use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::browse::{ExportFields, ExportRequest, build_export};
use tablepro_core::document::NUMBER_TYPE;
use tablepro_core::export::{CsvOptions, render_csv};
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, EditorSession, ReadStatement, ResultEvent, ResultSink, RunEnd, SinkFlow, Value};

use crate::support::{CALL, DATABASE, column_names, connect, editor, rows, run, start, unique, within};

type Events = Arc<Mutex<Vec<ResultEvent>>>;

struct Keep(Events);

#[async_trait]
impl ResultSink for Keep {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

/// Keeps what an export sends, and has another client run `late` once
/// the export has read its first rows, after its census.
struct WriteOnceStarted {
    kept: Events,
    writer: Arc<dyn EditorSession>,
    late: Option<String>,
    wrote: Arc<Mutex<Option<RunEnd>>>,
}

#[async_trait]
impl ResultSink for WriteOnceStarted {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        if matches!(event, ResultEvent::ResultSetStarted { .. })
            && let Some(late) = self.late.take()
        {
            let (summary, _) = run(self.writer.as_ref(), &late).await;
            *self.wrote.lock().unwrap_or_else(PoisonError::into_inner) = Some(summary.end);
        }
        self.kept.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

fn taken(events: &Events) -> Vec<ResultEvent> {
    std::mem::take(&mut *events.lock().unwrap_or_else(PoisonError::into_inner))
}

/// Every event an export of `table` under `filter` sent, with the
/// columns and identity the tab reads.
async fn export(connection: &dyn Connection, table: &TableRef, filter: &FilterSet) -> Vec<ResultEvent> {
    let kept = Arc::new(Mutex::new(Vec::new()));
    export_into(connection, table, filter, Box::new(Keep(kept.clone()))).await;
    taken(&kept)
}

async fn export_into(connection: &dyn Connection, table: &TableRef, filter: &FilterSet, sink: Box<dyn ResultSink>) {
    let columns = connection.fetch_columns(table, within(CALL)).await.expect("the fields");
    let identity = connection.row_identity(table, within(CALL)).await.expect("an identity");
    let request = ExportRequest {
        table,
        columns: &columns,
        filter,
        sort: &[],
        identity: &identity,
        fields: ExportFields::Every,
    };
    let statement = build_export(&*connection.dialect(), &request).expect("an export statement");
    connection
        .stream_read(&ReadStatement::Generated(statement), sink, within(CALL))
        .await
        .expect("the export");
}

fn assert_json(cell: &Value, expected: &str) {
    let read = match cell {
        Value::Json(json) => serde_json::from_str::<serde_json::Value>(json.as_str()).ok(),
        _ => None,
    };
    let expected = serde_json::from_str::<serde_json::Value>(expected).expect("JSON");
    assert_eq!(read.as_ref(), Some(&expected), "the cell is {cell:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_table_export_writes_the_fields_and_types_past_the_first_thousand_documents() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let collection = unique("late_fields");
    // Natural order is insertion order: `discount` and `n` first show in
    // the 1,001st document, past the census the tab's columns come from.
    let filled = fixture
        .shell(&format!(
            "const target = db.getSiblingDB('{DATABASE}').getCollection('{collection}');\n\
             target.insertMany(Array.from({{length: 1000}}, (_, id) => ({{_id: id, a: id}})));\n\
             target.insertMany([{{_id: 1000, a: 1000, discount: 0.25, n: NumberLong(5)}}, {{_id: 1001, a: 1001, n: 'five'}}]).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let tab = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the fields");
    let tab: Vec<&str> = tab.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(tab, ["_id", "a"], "the tab's census reads the first 1,000 documents");

    let events = export(connection.as_ref(), &table, &FilterSet::default()).await;

    assert_eq!(column_names(&events), ["_id", "a", "discount", "n"]);
    let written = rows(&events);
    assert_eq!(written.len(), 1002);
    assert_eq!(written[999][2], Value::Null);
    assert_eq!(written[1000][2], Value::Float64(0.25));
    assert_json(&written[1000][3], r#"{"$numberLong": "5"}"#);
    assert_json(&written[1001][3], r#""five""#);

    let nothing = FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "a".to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("-1".to_owned())),
        }],
        extra_sql: None,
    };
    let empty = export(connection.as_ref(), &table, &nothing).await;

    assert!(rows(&empty).is_empty(), "{empty:?}");
    assert_eq!(
        column_names(&empty),
        ["_id", "a"],
        "the collection's columns head an empty export"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_field_another_client_adds_while_a_table_export_reads_is_left_out() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let collection = unique("live_export");
    // About 100 KB each, so the server's batches hold fewer documents than
    // the export reads before its first rows, and a `getMore` follows them.
    let filled = fixture
        .shell(&format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertMany(\
             Array.from({{length: 400}}, (_, id) => ({{_id: id, a: id, pad: 'x'.repeat(100000)}}))).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    let table = TableRef::new(Some(DATABASE.to_owned()), collection.clone());
    let (kept, wrote) = (Arc::new(Mutex::new(Vec::new())), Arc::new(Mutex::new(None)));
    let sink = WriteOnceStarted {
        kept: kept.clone(),
        writer: editor(connection.as_ref()).await,
        late: Some(format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertOne({{_id: 400, a: 400, late: true}})"
        )),
        wrote: wrote.clone(),
    };

    export_into(connection.as_ref(), &table, &FilterSet::default(), Box::new(sink)).await;

    assert_eq!(
        *wrote.lock().unwrap_or_else(PoisonError::into_inner),
        Some(RunEnd::Completed)
    );
    let events = taken(&kept);
    assert_eq!(column_names(&events), ["_id", "a", "pad"]);
    let written = rows(&events);
    assert_eq!(written.len(), 401, "the export read the late document");
    assert_eq!(written[400], [Value::Int(400), Value::Int(400), Value::Null]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_table_export_keeps_the_tabs_column_order() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let collection = unique("tab_order");
    // Past the tab's census, a document puts `a` where the others put `b`.
    let filled = fixture
        .shell(&format!(
            "const target = db.getSiblingDB('{DATABASE}').getCollection('{collection}');\n\
             target.insertMany(Array.from({{length: 1000}}, (_, id) => ({{_id: id, b: id, a: id}})));\n\
             target.insertOne({{_id: 1000, a: 1000, c: 1}}).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    let table = TableRef::new(Some(DATABASE.to_owned()), collection);

    let events = export(connection.as_ref(), &table, &FilterSet::default()).await;

    assert_eq!(column_names(&events), ["_id", "b", "a", "c"]);
    assert_eq!(
        rows(&events)[1000],
        [Value::Int(1000), Value::Null, Value::Int(1000), Value::Int(1)]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_field_of_numbers_of_several_types_exports_as_numbers() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let collection = unique("number_export");
    let filled = fixture
        .shell(&format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertMany([\
             {{_id: 1, q: 1, m: 1}}, {{_id: 2, q: NumberLong('3000000000'), m: 'x'}}, {{_id: 3, q: 19.9}}]).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    let table = TableRef::new(Some(DATABASE.to_owned()), collection);

    let events = export(connection.as_ref(), &table, &FilterSet::default()).await;

    let Some(ResultEvent::ResultSetStarted { columns }) = events
        .iter()
        .find(|event| matches!(event, ResultEvent::ResultSetStarted { .. }))
    else {
        panic!("no result set in {events:?}");
    };
    let types: Vec<&str> = columns.iter().map(|column| column.column_type.name.as_str()).collect();
    assert_eq!(types, ["int", NUMBER_TYPE, "object"]);
    let csv = render_csv(columns, &rows(&events), &CsvOptions::default()).expect("the CSV");
    assert_eq!(csv, "_id,q,m\n1,1,1\n2,3000000000,\"\"\"x\"\"\"\n3,19.9,\n");
}
