use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;
use tablepro_core::{
    ByteLimit, ByteLimitSink, EditorSessionOptions, ResultEvent, ResultSink, RunEnd, RunOptions, SinkFlow, Truncation,
    UserSql, WriteKind,
};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    apply, connect, create_scratch_table, dial, expect, insert_sql, run_completed, run_options, unique, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure, DocumentEngine, test_liveness};
use crate::lock;

const CASE: &str = "byte_limit_keeps_whole_rows_and_later_statements";
const DOCUMENT_CASE: &str = "a_document_read_stops_at_the_byte_limit";

const ROWS: usize = 40;
// Under the narrowest scratch label column, SQL Server's nvarchar(200).
const LABEL_CHARS: usize = 160;
const KEPT_ROWS: u64 = 16;
const DOCUMENTS: u32 = 1_234;
const DOCUMENT_LIMIT_BYTES: u64 = 1_024;

fn label(id: i64) -> String {
    format!("{id:04}{}", "x".repeat(LABEL_CHARS - 4))
}

fn text_of(value: &Value) -> Option<&str> {
    match value {
        Value::Text(text) => Some(text),
        Value::Bytes(bytes) => std::str::from_utf8(bytes).ok(),
        Value::Other(other) => Some(&other.text),
        _ => None,
    }
}

fn row_bytes(row: &[Value]) -> u64 {
    row.iter().map(|value| value.retained_bytes() as u64).sum()
}

#[derive(Clone, Default)]
struct Events(Arc<Mutex<Vec<ResultEvent>>>);

#[async_trait]
impl ResultSink for Events {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        lock(&self.0).push(event);
        SinkFlow::Continue
    }
}

impl Events {
    fn rows(&self) -> Vec<Vec<Value>> {
        lock(&self.0)
            .iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    fn column(&self, name: &str) -> Option<usize> {
        lock(&self.0).iter().find_map(|event| match event {
            ResultEvent::ResultSetStarted { columns } => columns.iter().position(|column| column.name == name),
            _ => None,
        })
    }

    // One `ByteLimitReached` for the rows kept, and a finish that says the set was cut for size.
    fn check_cut(&self, case: &'static str, kept: usize) -> Result<(), ConformanceFailure> {
        let events = lock(&self.0).clone();
        let reached: Vec<u64> = events
            .iter()
            .filter_map(|event| match event {
                ResultEvent::ByteLimitReached { retained } => Some(*retained),
                _ => None,
            })
            .collect();
        expect(case, reached == [kept as u64], || {
            format!("{kept} rows were kept, but the byte limit events were {reached:?}")
        })?;
        let truncations: Vec<Truncation> = events
            .iter()
            .filter_map(|event| match event {
                ResultEvent::ResultSetFinished { truncation, .. } => Some(*truncation),
                _ => None,
            })
            .collect();
        expect(case, truncations == [Truncation::ByteLimit], || {
            format!("the read finished with {truncations:?}")
        })
    }
}

// Through the sink the session puts around every editor run, as an app's run goes.
pub async fn byte_limit_keeps_whole_rows_and_later_statements<E: ConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "byte_limit").await?;
    let dialect = connection.dialect();
    let inserts = (1..=ROWS as i64)
        .map(|id| insert_sql(dialect.as_ref(), &table, id, &label(id)))
        .collect();
    apply(connection.as_ref(), &table, WriteKind::RowChanges, inserts).await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let row = (2 * size_of::<Value>() + LABEL_CHARS) as u64;
    let limit = ByteLimit::new(row * KEPT_ROWS).ok_or_else(|| ConformanceFailure::setup("a byte limit of zero"))?;
    let select = format!(
        "SELECT {}, {} FROM {}",
        dialect.quote_identifier("id"),
        dialect.quote_identifier("label"),
        dialect.qualify(&table)
    );

    let events = Events::default();
    let sink = Box::new(ByteLimitSink::new(Box::new(events.clone()), limit));
    let options = RunOptions::new(CancellationToken::new()).with_byte_limit(limit);
    let summary = session.run(UserSql::new(select), options, sink).await?;

    expect(CASE, summary.end == RunEnd::Completed, || {
        format!("the limited read ended {:?}", summary.end)
    })?;
    let rows = events.rows();
    let kept = rows.len();
    expect(CASE, kept > 0 && kept < ROWS, || {
        format!("the read kept {kept} of {ROWS} rows")
    })?;
    let before_last: u64 = rows.iter().take(kept - 1).map(|row| row_bytes(row)).sum();
    let with_last = rows.iter().map(|row| row_bytes(row)).sum::<u64>();
    expect(CASE, before_last < limit.get() && with_last >= limit.get(), || {
        format!(
            "{kept} rows were kept: {before_last} bytes before the last and {with_last} with it, under {}",
            limit.get()
        )
    })?;
    let whole = rows.iter().all(|row| {
        row.get(1)
            .and_then(text_of)
            .is_some_and(|text| text.len() == LABEL_CHARS && text.ends_with('x'))
    });
    expect(CASE, whole, || "a kept label was not whole".to_owned())?;
    events.check_cut(CASE, kept)?;
    let after = run_completed(CASE, session.as_ref(), &engine.row_source_sql(1), run_options()).await?;
    let counted = after.rows().len();
    expect(CASE, counted == 1, || {
        format!("the statement after the cut returned {counted} rows")
    })?;

    session.close().await;
    connection.close().await?;
    Ok(())
}

// No sink here: a document engine holds a cursor's documents before its first row, so the driver itself stops.
pub async fn a_document_read_stops_at_the_byte_limit<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let options = engine.connect_options(writable(), test_liveness());
    let connection = dial(DOCUMENT_CASE, E::driver(), options).await??;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let table = TableRef::new(Some(engine.database().to_owned()), unique("documents"));
    let fill = engine.fill_statements(&table.name, DOCUMENTS);
    run_completed(DOCUMENT_CASE, session.as_ref(), &fill, run_options()).await?;
    let limit =
        ByteLimit::new(DOCUMENT_LIMIT_BYTES).ok_or_else(|| ConformanceFailure::setup("a byte limit of zero"))?;

    let events = Events::default();
    let find = format!("db.getCollection(\"{}\").find()", table.name);
    let options = RunOptions::new(CancellationToken::new()).with_byte_limit(limit);
    let summary = session
        .run(UserSql::new(find), options, Box::new(events.clone()))
        .await?;

    expect(DOCUMENT_CASE, summary.end == RunEnd::Completed, || {
        format!("the limited find ended {:?}", summary.end)
    })?;
    let label = events
        .column("label")
        .ok_or_else(|| ConformanceFailure::setup("the find has no label column"))?;
    let rows = events.rows();
    let kept = rows.len();
    expect(DOCUMENT_CASE, kept > 0 && kept < DOCUMENTS as usize, || {
        format!("the find kept {kept} of {DOCUMENTS} documents under {DOCUMENT_LIMIT_BYTES} bytes")
    })?;
    let whole = rows.iter().all(|row| {
        row.get(label)
            .and_then(text_of)
            .is_some_and(|text| text.starts_with("row "))
    });
    expect(DOCUMENT_CASE, whole, || "a kept label was not whole".to_owned())?;
    events.check_cut(DOCUMENT_CASE, kept)?;
    let one = format!("db.getCollection(\"{}\").find({{_id: 1}})", table.name);
    let after = run_completed(DOCUMENT_CASE, session.as_ref(), &one, run_options()).await?;
    let found = after.rows().len();
    expect(DOCUMENT_CASE, found == 1, || {
        format!("the find after the cut returned {found} rows")
    })?;

    session.close().await;
    connection.close().await?;
    Ok(())
}
