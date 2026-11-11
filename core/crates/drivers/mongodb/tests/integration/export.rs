//! A table export as the export dialog's Entire Table reads it: the
//! statement `build_export` writes for every field, then `stream_read`.

use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::browse::{ExportFields, ExportRequest, build_export};
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, ReadStatement, ResultEvent, ResultSink, SinkFlow, Value};

use crate::support::{CALL, DATABASE, column_names, connect, rows, start, unique, within};

struct Keep(Arc<Mutex<Vec<ResultEvent>>>);

#[async_trait]
impl ResultSink for Keep {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).push(event);
        SinkFlow::Continue
    }
}

/// Every event an export of `table` under `filter` sent, with the
/// columns and identity the tab reads.
async fn export(connection: &dyn Connection, table: &TableRef, filter: &FilterSet) -> Vec<ResultEvent> {
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
    let kept = Arc::new(Mutex::new(Vec::new()));
    connection
        .stream_read(
            &ReadStatement::Generated(statement),
            Box::new(Keep(kept.clone())),
            within(CALL),
        )
        .await
        .expect("the export");
    std::mem::take(&mut *kept.lock().unwrap_or_else(PoisonError::into_inner))
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
