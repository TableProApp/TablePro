//! The document suite: what a document engine's connection does with
//! collections in the table tab's terms, and how its editor runs
//! statements and stops them.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::browse::{PageRead, PageRequest, SortKey, build_count, read_page};
use tablepro_core::column::ColumnKind;
use tablepro_core::edit::CellInput;
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::{ObjectKind, ObjectScope, PagePosition, RowIdentity, TableRef};
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::{
    ColumnInfo, Connection, DataModel, DriverError, EditorSession, EditorSessionOptions, EditorSessionState,
    ErrorCategory, LinkState, ReadStatement, RowLimit, RunEnd, RunOptions, Truncation, UserSql, Value,
    WorkspaceSettings,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    CALL_DEADLINE, Collected, SCHEDULING_SLACK, dial, expect, run_completed, run_editor, run_options, unexpected,
    unique, within, writable,
};
use crate::conformance::{ConformanceFailure, DocumentEngine, test_liveness};

/// Long enough for a statement to reach the server before the case stops
/// it, so the stop is tested rather than a race with sending.
const SETTLE: Duration = Duration::from_millis(500);

/// More documents than two pages hold, so paging reads a third.
const MANY: u32 = 1_234;

const PAGE: u64 = 500;

async fn connect<E: DocumentEngine>(
    case: &'static str,
    engine: &E,
    settings: WorkspaceSettings,
) -> Result<Arc<dyn Connection>, ConformanceFailure> {
    Ok(dial(case, E::driver(), engine.connect_options(settings, test_liveness())).await??)
}

async fn editor(connection: &dyn Connection) -> Result<Arc<dyn EditorSession>, ConformanceFailure> {
    Ok(connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?)
}

/// A collection of `documents` documents, written through an editor.
async fn filled<E: DocumentEngine>(
    case: &'static str,
    engine: &E,
    connection: &dyn Connection,
    documents: u32,
) -> Result<TableRef, ConformanceFailure> {
    let name = unique("documents");
    let session = editor(connection).await?;
    run_completed(
        case,
        session.as_ref(),
        &engine.fill_statements(&name, documents),
        run_options(),
    )
    .await?;
    session.close().await;
    Ok(TableRef::new(Some(engine.database().to_owned()), name))
}

/// A collection's columns and the identity its rows are named by.
async fn shape(
    connection: &dyn Connection,
    table: &TableRef,
) -> Result<(Vec<ColumnInfo>, RowIdentity), ConformanceFailure> {
    let columns = connection.fetch_columns(table, within(CALL_DEADLINE)).await?;
    let identity = connection.row_identity(table, within(CALL_DEADLINE)).await?;
    Ok((columns, identity))
}

async fn page(
    case: &'static str,
    connection: &dyn Connection,
    table: &TableRef,
    filter: &FilterSet,
    sort: &[SortKey],
    position: &PagePosition,
) -> Result<PageRead, ConformanceFailure> {
    let (columns, identity) = shape(connection, table).await?;
    let request = PageRequest {
        table,
        columns: &columns,
        filter,
        sort,
        identity: &identity,
        position,
        limit: PAGE,
    };
    read_page::<Box<dyn std::error::Error + Send + Sync>>(connection, &request, &within(CALL_DEADLINE))
        .await
        .map_err(|error| unexpected(case, format!("the page did not read: {error:?}")))
}

fn ids(read: &PageRead) -> Vec<i64> {
    read.result
        .rows
        .iter()
        .filter_map(|row| match row.first() {
            Some(Value::Int(id)) => Some(*id),
            _ => None,
        })
        .collect()
}

const LISTED_CASE: &str = "collections_are_listed_in_their_database";

/// A collection is listed in its database, which is listed among the
/// databases, as a table the grid opens.
pub async fn collections_are_listed_in_their_database<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(LISTED_CASE, &engine, writable()).await?;
    let table = filled(LISTED_CASE, &engine, connection.as_ref(), 3).await?;

    let schemas = connection.list_schemas(within(CALL_DEADLINE)).await?;
    let objects = connection
        .list_objects(
            &ObjectScope::Schema(engine.database().to_owned()),
            within(CALL_DEADLINE),
        )
        .await?;

    expect(
        LISTED_CASE,
        schemas
            .iter()
            .any(|schema| schema.name == engine.database() && schema.is_default),
        || format!("the connection's database is not the default among {schemas:?}"),
    )?;
    let listed = objects.iter().find(|object| object.name == table.name);
    expect(
        LISTED_CASE,
        listed.is_some_and(|object| object.kind == ObjectKind::Table),
        || format!("{} is not listed as a table among {objects:?}", table.name),
    )?;
    connection.close().await?;
    Ok(())
}

const FIELDS_CASE: &str = "fields_become_columns_with_the_id_first";

/// The fields the documents hold are the columns, `_id` first and the
/// key, and a field that nests is JSON.
pub async fn fields_become_columns_with_the_id_first<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(FIELDS_CASE, &engine, writable()).await?;
    let table = filled(FIELDS_CASE, &engine, connection.as_ref(), 3).await?;

    let (columns, identity) = shape(connection.as_ref(), &table).await?;

    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    expect(FIELDS_CASE, names == ["_id", "label", "nested"], || {
        format!("the columns are {names:?}")
    })?;
    expect(FIELDS_CASE, columns[0].primary_key, || {
        "`_id` is not the key".to_owned()
    })?;
    expect(
        FIELDS_CASE,
        matches!(columns[2].column_type.kind, ColumnKind::Json { .. }),
        || format!("a nested document's column is {:?}", columns[2].column_type.kind),
    )?;
    expect(
        FIELDS_CASE,
        identity
            == RowIdentity::UniqueKey {
                columns: vec!["_id".to_owned()],
            },
        || format!("the documents are named by {identity:?}"),
    )?;
    connection.close().await?;
    Ok(())
}

const PAGES_CASE: &str = "pages_read_every_document_in_order";

/// Pages read past each other's last key reach every document once, in
/// `_id` order, and the last page reads back from the end.
pub async fn pages_read_every_document_in_order<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(PAGES_CASE, &engine, writable()).await?;
    let table = filled(PAGES_CASE, &engine, connection.as_ref(), MANY).await?;
    let filter = FilterSet::default();

    let mut seen = Vec::new();
    let mut position = PagePosition::First;
    for _ in 0..10 {
        let read = page(PAGES_CASE, connection.as_ref(), &table, &filter, &[], &position).await?;
        seen.extend(ids(&read));
        // A short page is the last one.
        match (read.result.rows.len() as u64 == PAGE, read.next) {
            (true, Some(next)) => position = next,
            _ => break,
        }
    }
    let last = page(
        PAGES_CASE,
        connection.as_ref(),
        &table,
        &filter,
        &[],
        &PagePosition::Last,
    )
    .await?;

    let expected: Vec<i64> = (1..=i64::from(MANY)).collect();
    expect(PAGES_CASE, seen == expected, || {
        format!("the pages read {} documents, not 1 to {MANY} in order", seen.len())
    })?;
    let tail = ids(&last);
    expect(
        PAGES_CASE,
        tail.first() == Some(&(i64::from(MANY) - 499)) && tail.last() == Some(&i64::from(MANY)),
        || format!("the last page read {:?} to {:?}", tail.first(), tail.last()),
    )?;
    connection.close().await?;
    Ok(())
}

const FILTER_CASE: &str = "a_filter_and_a_sort_are_read_on_the_server";

/// A rule and a sort reach the server: the count is the matching
/// documents', and the first page starts where the sort says.
pub async fn a_filter_and_a_sort_are_read_on_the_server<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(FILTER_CASE, &engine, writable()).await?;
    let table = filled(FILTER_CASE, &engine, connection.as_ref(), 149).await?;
    let filter = FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "label".to_owned(),
            op: FilterOp::StartsWith,
            value: Some(FilterValue::Single("row 1".to_owned())),
        }],
        extra_sql: None,
    };
    let (columns, _) = shape(connection.as_ref(), &table).await?;

    let statement = build_count(&*connection.dialect(), &table, &columns, &filter)
        .map_err(|error| unexpected(FILTER_CASE, format!("the count did not build: {error}")))?;
    let counted = connection.count_rows(&statement, within(CALL_DEADLINE)).await?;
    let sort = [SortKey {
        column: 0,
        ascending: false,
    }];
    let sorted = page(
        FILTER_CASE,
        connection.as_ref(),
        &table,
        &filter,
        &sort,
        &PagePosition::First,
    )
    .await?;

    // "row 1", "row 10" to "row 19" and "row 100" to "row 149".
    expect(FILTER_CASE, counted == 61, || {
        format!("the filter counted {counted} documents, not 61")
    })?;
    expect(FILTER_CASE, ids(&sorted).first() == Some(&149), || {
        format!("the sorted page starts at {:?}, not 149", ids(&sorted).first())
    })?;
    connection.close().await?;
    Ok(())
}

async fn save(
    connection: &dyn Connection,
    table: &TableRef,
    changes: Vec<RowChange>,
) -> Result<Result<tablepro_core::WriteReport, DriverError>, ConformanceFailure> {
    let (columns, identity) = shape(connection, table).await?;
    let plan = plan_save(
        &*connection.dialect(),
        table,
        &columns,
        &identity,
        &ChangeSet { changes },
    )
    .map_err(|error| ConformanceFailure::setup(format!("the save did not plan: {error}")))?;
    Ok(connection.write_batch(&plan.batch, within(CALL_DEADLINE)).await)
}

async fn label_of(
    case: &'static str,
    connection: &dyn Connection,
    table: &TableRef,
    id: i64,
) -> Result<Option<Value>, ConformanceFailure> {
    let read = page(
        case,
        connection,
        table,
        &FilterSet::default(),
        &[],
        &PagePosition::First,
    )
    .await?;
    Ok(read
        .result
        .rows
        .iter()
        .find(|row| row.first() == Some(&Value::Int(id)))
        .and_then(|row| row.get(1).cloned()))
}

const EDIT_CASE: &str = "a_field_edit_saves_and_reads_back";

/// One field changed in the grid is the only field that changes.
pub async fn a_field_edit_saves_and_reads_back<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(EDIT_CASE, &engine, writable()).await?;
    let table = filled(EDIT_CASE, &engine, connection.as_ref(), 10).await?;

    let report = save(
        connection.as_ref(),
        &table,
        vec![RowChange::Update(RowUpdate {
            key: vec![Value::Int(7)],
            assignments: vec![(1, Value::Text("renamed".to_owned()))],
        })],
    )
    .await??;
    let label = label_of(EDIT_CASE, connection.as_ref(), &table, 7).await?;

    expect(EDIT_CASE, report.rows_affected == [Some(1)], || {
        format!("the save reported {:?}", report.rows_affected)
    })?;
    expect(EDIT_CASE, label == Some(Value::Text("renamed".to_owned())), || {
        format!("the edited field reads {label:?}")
    })?;
    connection.close().await?;
    Ok(())
}

const GONE_CASE: &str = "a_save_on_a_document_that_is_gone_changes_nothing";

/// An edit of a document someone else deleted matches nothing, and says
/// so instead of reporting a save.
pub async fn a_save_on_a_document_that_is_gone_changes_nothing<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(GONE_CASE, &engine, writable()).await?;
    let table = filled(GONE_CASE, &engine, connection.as_ref(), 3).await?;
    save(
        connection.as_ref(),
        &table,
        vec![RowChange::Delete {
            key: vec![Value::Int(2)],
        }],
    )
    .await??;

    let outcome = save(
        connection.as_ref(),
        &table,
        vec![RowChange::Update(RowUpdate {
            key: vec![Value::Int(2)],
            assignments: vec![(1, Value::Text("ghost".to_owned()))],
        })],
    )
    .await?;

    expect(
        GONE_CASE,
        matches!(&outcome, Err(DriverError::RowGuardFailed { .. })),
        || format!("an edit of a deleted document gave {outcome:?}"),
    )?;
    let label = label_of(GONE_CASE, connection.as_ref(), &table, 2).await?;
    expect(GONE_CASE, label.is_none(), || {
        format!("the deleted document came back as {label:?}")
    })?;
    connection.close().await?;
    Ok(())
}

const INSERT_CASE: &str = "an_insert_and_a_delete_land";

/// A new row becomes a document with the fields set, and a deleted row's
/// document is gone.
pub async fn an_insert_and_a_delete_land<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(INSERT_CASE, &engine, writable()).await?;
    let table = filled(INSERT_CASE, &engine, connection.as_ref(), 3).await?;

    let report = save(
        connection.as_ref(),
        &table,
        vec![
            RowChange::Insert {
                cells: vec![
                    CellInput::Value(Value::Int(100)),
                    CellInput::Value(Value::Text("new".to_owned())),
                    CellInput::Default,
                ],
            },
            RowChange::Delete {
                key: vec![Value::Int(1)],
            },
        ],
    )
    .await??;

    expect(INSERT_CASE, report.rows_affected == [Some(1), Some(1)], || {
        format!("the save reported {:?}", report.rows_affected)
    })?;
    let inserted = label_of(INSERT_CASE, connection.as_ref(), &table, 100).await?;
    let deleted = label_of(INSERT_CASE, connection.as_ref(), &table, 1).await?;
    expect(INSERT_CASE, inserted == Some(Value::Text("new".to_owned())), || {
        format!("the inserted document reads {inserted:?}")
    })?;
    expect(INSERT_CASE, deleted.is_none(), || {
        format!("the deleted document reads {deleted:?}")
    })?;
    connection.close().await?;
    Ok(())
}

const READ_ONLY_CASE: &str = "a_read_only_connection_refuses_writes_before_sending";

/// On a read-only connection a write never reaches the server: a save, a
/// write in the editor, a read that writes its results and a write in an
/// export are all refused, and a read still runs.
pub async fn a_read_only_connection_refuses_writes_before_sending<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let writer = connect(READ_ONLY_CASE, &engine, writable()).await?;
    let table = filled(READ_ONLY_CASE, &engine, writer.as_ref(), 3).await?;
    let read_only = connect(READ_ONLY_CASE, &engine, WorkspaceSettings::workspace(true)).await?;
    let session = editor(read_only.as_ref()).await?;
    let target = unique("written");

    let saved = save(
        read_only.as_ref(),
        &table,
        vec![RowChange::Delete {
            key: vec![Value::Int(1)],
        }],
    )
    .await?;
    let (written, _) = run_editor(
        session.as_ref(),
        &engine.writing_read(&table.name, &target),
        run_options(),
    )
    .await?;
    let streamed = read_only
        .stream_read(
            &ReadStatement::User(UserSql::new(engine.writing_read(&table.name, &target))),
            Collected::default().sink(),
            within(CALL_DEADLINE),
        )
        .await;

    let refused = |error: &DriverError| matches!(error, DriverError::ReadOnly(_));
    expect(READ_ONLY_CASE, saved.as_ref().is_err_and(refused), || {
        format!("a save on a read-only connection gave {saved:?}")
    })?;
    expect(
        READ_ONLY_CASE,
        matches!(&written.end, RunEnd::Failed(error) if refused(error)),
        || format!("a read that writes ended {:?}", written.end),
    )?;
    expect(READ_ONLY_CASE, streamed.as_ref().is_err_and(refused), || {
        format!("a write streamed on a read-only connection gave {streamed:?}")
    })?;
    let objects = writer
        .list_objects(
            &ObjectScope::Schema(engine.database().to_owned()),
            within(CALL_DEADLINE),
        )
        .await?;
    expect(
        READ_ONLY_CASE,
        !objects.iter().any(|object| object.name == target),
        || format!("the refused write made {target}"),
    )?;
    let kept = label_of(READ_ONLY_CASE, writer.as_ref(), &table, 1).await?;
    expect(READ_ONLY_CASE, kept.is_some(), || {
        "the refused save deleted a document".to_owned()
    })?;
    session.close().await;
    read_only.close().await?;
    writer.close().await?;
    Ok(())
}

/// Wait until the server runs no operation tagged with `marker`, or
/// `bound` passes.
async fn until_stopped<E: DocumentEngine>(
    case: &'static str,
    engine: &E,
    marker: &str,
    bound: Duration,
) -> Result<(), ConformanceFailure> {
    let give_up = Instant::now() + bound;
    loop {
        let running = engine.running_operations(marker).await?;
        if running == 0 {
            return Ok(());
        }
        if Instant::now() >= give_up {
            return Err(unexpected(
                case,
                format!("{running} operations were still running after {bound:?}"),
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

const STOPPED_CASE: &str = "a_stopped_statement_ends_and_the_session_runs_again";

/// A statement running on the server ends as cancelled within the cancel
/// grace, the server stops it, and the session takes the next run.
pub async fn a_stopped_statement_ends_and_the_session_runs_again<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let grace = test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(STOPPED_CASE, &engine, writable()).await?;
    let table = filled(STOPPED_CASE, &engine, connection.as_ref(), 50).await?;
    let session = editor(connection.as_ref()).await?;
    let marker = unique("stopped");
    let cancel = CancellationToken::new();
    let statement = engine.unbounded_statement(&table.name, &marker);

    let running = async {
        let outcome = run_editor(session.as_ref(), &statement, RunOptions::new(cancel.clone())).await;
        (outcome, Instant::now())
    };
    let cancelling = async {
        tokio::time::sleep(SETTLE).await;
        cancel.cancel();
        Instant::now()
    };
    let ((outcome, finished), cancelled) = tokio::join!(running, cancelling);
    let (summary, _) = outcome?;
    let after_cancel = finished.saturating_duration_since(cancelled);

    expect(STOPPED_CASE, summary.end == RunEnd::Cancelled, || {
        format!("the stopped statement ended {:?}", summary.end)
    })?;
    expect(STOPPED_CASE, after_cancel <= grace, || {
        format!("the run ended {after_cancel:?} after its cancel, past the {grace:?} grace")
    })?;
    expect(STOPPED_CASE, session.state() == EditorSessionState::Ready, || {
        format!("the session is {:?} after a stop", session.state())
    })?;
    until_stopped(STOPPED_CASE, &engine, &marker, grace).await?;
    run_completed(
        STOPPED_CASE,
        session.as_ref(),
        &engine.fill_statements(&unique("after"), 1),
        run_options(),
    )
    .await?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const DROPPED_CASE: &str = "a_dropped_editor_run_stops_the_statement";

/// Dropping the caller of a run stops the statement on the server rather
/// than leaving it running for nobody.
pub async fn a_dropped_editor_run_stops_the_statement<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let bound = test_liveness().cancel_grace + Duration::from_secs(1);
    let connection = connect(DROPPED_CASE, &engine, writable()).await?;
    let table = filled(DROPPED_CASE, &engine, connection.as_ref(), 50).await?;
    let session = editor(connection.as_ref()).await?;
    let marker = unique("dropped");
    let statement = engine.unbounded_statement(&table.name, &marker);

    let running = run_editor(session.as_ref(), &statement, run_options());
    let dropped = tokio::time::timeout(SETTLE, running).await;
    expect(DROPPED_CASE, dropped.is_err(), || {
        format!("the statement ended on its own: {dropped:?}")
    })?;

    until_stopped(DROPPED_CASE, &engine, &marker, bound).await?;
    let state = session.state();
    expect(
        DROPPED_CASE,
        matches!(state, EditorSessionState::Ready | EditorSessionState::Lost),
        || format!("the session is {state:?} after its run was dropped"),
    )?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const TIMEOUT_CASE: &str = "a_timed_out_statement_is_stopped_by_the_server";

/// A statement past the session's timeout is stopped by the server's own
/// time limit, and the session takes the next run.
pub async fn a_timed_out_statement_is_stopped_by_the_server<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(TIMEOUT_CASE, &engine, writable()).await?;
    let table = filled(TIMEOUT_CASE, &engine, connection.as_ref(), 50).await?;
    let options = EditorSessionOptions {
        statement_timeout: Some(SETTLE),
    };
    let session = connection
        .open_editor_session(options, CancellationToken::new())
        .await?;

    let (summary, _) = run_editor(
        session.as_ref(),
        &engine.unbounded_statement(&table.name, &unique("timeout")),
        run_options(),
    )
    .await?;

    expect(
        TIMEOUT_CASE,
        summary.end == RunEnd::TimedOut { server_cancelled: true },
        || format!("the timed-out statement ended {:?}", summary.end),
    )?;
    expect(TIMEOUT_CASE, session.state() == EditorSessionState::Ready, || {
        format!("the session is {:?} after a timeout", session.state())
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const LIMIT_CASE: &str = "an_editor_result_keeps_the_row_limit";

/// A read past the row limit keeps the limit's worth and says the result
/// was cut.
pub async fn an_editor_result_keeps_the_row_limit<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(LIMIT_CASE, &engine, writable()).await?;
    let table = filled(LIMIT_CASE, &engine, connection.as_ref(), MANY).await?;
    let session = editor(connection.as_ref()).await?;
    let limit = RowLimit::new(100).ok_or_else(|| ConformanceFailure::setup("a limit of 100".to_owned()))?;
    let options = RunOptions {
        row_limit: limit,
        ..run_options()
    };

    let collected = run_completed(
        LIMIT_CASE,
        session.as_ref(),
        &format!("db.getCollection(\"{}\").find()", table.name),
        options,
    )
    .await?;

    let rows = collected.rows().len();
    expect(LIMIT_CASE, rows == 100, || {
        format!("the result kept {rows} rows, not 100")
    })?;
    let truncations = collected.truncations();
    expect(LIMIT_CASE, truncations == [Truncation::ReadPastLimit], || {
        format!("the result ended {truncations:?}")
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const STREAM_CASE: &str = "stream_read_streams_every_document";

pub async fn stream_read_streams_every_document<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(STREAM_CASE, &engine, writable()).await?;
    let table = filled(STREAM_CASE, &engine, connection.as_ref(), MANY).await?;
    let collected = Collected::default();

    let summary = connection
        .stream_read(
            &ReadStatement::User(UserSql::new(format!("db.getCollection(\"{}\").find()", table.name))),
            collected.sink(),
            within(CALL_DEADLINE),
        )
        .await?;

    let rows = collected.rows().len();
    expect(
        STREAM_CASE,
        rows == MANY as usize && summary.rows == u64::from(MANY),
        || format!("streamed {rows} rows, summary {}, of {MANY}", summary.rows),
    )?;
    connection.close().await?;
    Ok(())
}

const PROBE_CASE: &str = "a_probe_answers_while_a_statement_runs";

pub async fn a_probe_answers_while_a_statement_runs<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let connection = connect(PROBE_CASE, &engine, writable()).await?;
    let table = filled(PROBE_CASE, &engine, connection.as_ref(), 50).await?;
    let session = editor(connection.as_ref()).await?;
    let cancel = CancellationToken::new();
    let statement = engine.unbounded_statement(&table.name, &unique("probe"));

    let running = run_editor(session.as_ref(), &statement, RunOptions::new(cancel.clone()));
    let probing = async {
        tokio::time::sleep(SETTLE).await;
        let probed = connection.probe(within(liveness.probe_timeout)).await;
        cancel.cancel();
        probed
    };
    let (_, probed) = tokio::join!(running, probing);

    expect(PROBE_CASE, probed.is_ok(), || {
        format!("a probe beside a running statement gave {probed:?}")
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const CLOSE_CASE: &str = "document_close_is_idempotent";

pub async fn document_close_is_idempotent<E: DocumentEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let connection = connect(CLOSE_CASE, &engine, writable()).await?;
    connection.probe(within(liveness.probe_timeout)).await?;
    let close_bound = liveness.close_timeout + liveness.cancel_grace + SCHEDULING_SLACK;

    for attempt in ["first", "second"] {
        let closed = tokio::time::timeout(close_bound, connection.close()).await;
        expect(CLOSE_CASE, matches!(closed, Ok(Ok(()))), || {
            format!("the {attempt} close gave {closed:?} within {close_bound:?}")
        })?;
    }
    let after = tokio::time::timeout(close_bound, connection.list_schemas(within(CALL_DEADLINE))).await;
    expect(CLOSE_CASE, matches!(after, Ok(Err(_))), || {
        format!("a read after close gave {after:?}")
    })?;
    Ok(())
}

const LOST_CASE: &str = "a_lost_transport_reports_connection_lost_to_a_read";
const LOST_DEADLINE: Duration = Duration::from_secs(1);

pub async fn a_lost_transport_reports_connection_lost_to_a_read<E: DocumentEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let (options, fault) = engine.faulty_connect_options(writable(), liveness).await?;
    let connection = dial(LOST_CASE, E::driver(), options).await??;
    connection.list_schemas(within(CALL_DEADLINE)).await?;

    fault.black_hole();
    let started = Instant::now();
    let outcome = connection.list_schemas(within(LOST_DEADLINE)).await;
    let elapsed = started.elapsed();
    let bound = LOST_DEADLINE + liveness.cancel_grace + SCHEDULING_SLACK;

    let lost = matches!(&outcome, Err(error) if error.category() == ErrorCategory::ConnectionLost);
    expect(LOST_CASE, lost, || {
        format!("a read over a dropped route gave {outcome:?}")
    })?;
    expect(LOST_CASE, elapsed <= bound, || {
        format!("the loss was reported after {elapsed:?}, past the {bound:?} bound")
    })?;
    expect(LOST_CASE, connection.link_state() == LinkState::Lost, || {
        format!("the link is {:?} after the loss", connection.link_state())
    })?;
    drop(connection.close().await);
    Ok(())
}

const MODEL_CASE: &str = "document_suite_matches_driver_capabilities";

/// Only a driver that says it holds documents runs this suite.
pub fn document_suite_matches_driver_capabilities<E: DocumentEngine>() -> Result<(), ConformanceFailure> {
    let model = E::driver().capabilities().data_model;
    expect(MODEL_CASE, model == DataModel::Document, || {
        format!("the document suite runs on a driver whose data model is {model:?}")
    })
}
