//! A stop on a server that refuses `killSessions`, as Atlas M0 and Flex
//! do: the `failCommand` fail point refuses it here, and the stop ends the
//! call's operations by id instead.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    CallOptions, DriverError, EditorSession, LinkState, ReadStatement, ResultEvent, ResultSink, RunEnd, RunOptions,
    ServerCode, SinkFlow, UserSql, Value,
};
use tablepro_test_fixtures::MongoFixture;
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{CALL, DATABASE, connect, editor, rows, run, run_with, sink, unique};

/// `CommandNotFound`, what the fail point answers `killSessions` with.
const REFUSED: i32 = 59;

/// How long a statement may take to show on the server.
const REACHED: Duration = Duration::from_secs(5);

/// A server whose every `killSessions` fails, and a collection whose
/// documents each take a second of server-side JavaScript to read.
async fn refusing_kill_sessions() -> (MongoFixture, String) {
    let fixture = MongoFixture::start_with_test_commands()
        .await
        .expect("a MongoDB container with test commands");
    let set = fixture
        .shell(&format!(
            "db.adminCommand({{configureFailPoint: 'failCommand', mode: 'alwaysOn', \
             data: {{failCommands: ['killSessions'], errorCode: {REFUSED}}}}}).ok"
        ))
        .await
        .expect("mongosh ran");
    assert!(
        set.succeeded() && set.stdout_text().trim() == "1",
        "the fail point is not set: {} {}",
        set.stdout_text(),
        set.stderr_text()
    );
    let collection = unique("slow");
    let filled = fixture
        .shell(&format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertMany(\
             Array.from({{length: 50}}, (_, n) => ({{_id: n, label: 'row ' + n}}))).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    (fixture, collection)
}

fn slow_find(collection: &str, marker: &str) -> String {
    format!(
        "db.getCollection('{collection}').find({{$where: 'sleep(1000) || true'}}, {{label: 1}}).comment('{marker}')"
    )
}

/// How many operations tagged with `marker` the server runs, as it
/// counts them, `Int(0)` for none.
async fn running(watcher: &dyn EditorSession, marker: &str) -> Value {
    let (summary, events) = run(
        watcher,
        &format!(
            "db.getSiblingDB('admin').aggregate([{{$currentOp: {{allUsers: true}}}}, \
             {{$match: {{'command.comment': '{marker}'}}}}, {{$count: 'n'}}])"
        ),
    )
    .await;
    assert_eq!(summary.end, RunEnd::Completed);
    rows(&events)
        .first()
        .and_then(|row| row.first())
        .cloned()
        .unwrap_or(Value::Int(0))
}

/// Cancel once the server runs the statement tagged with `marker`, so
/// the stop has an operation to find.
async fn cancel_once_running(watcher: &dyn EditorSession, marker: &str, cancel: &CancellationToken) -> Instant {
    let give_up = Instant::now() + REACHED;
    while running(watcher, marker).await == Value::Int(0) {
        assert!(Instant::now() < give_up, "the statement never reached the server");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    cancel.cancel();
    Instant::now()
}

// Without this a stop would pass on a server that took killSessions, the fallback never run.
async fn assert_kill_sessions_refused(session: &dyn EditorSession) {
    let (summary, _) = run(
        session,
        "db.adminCommand({killSessions: [{id: UUID('0e3f6f0e-8a3b-4b8e-9a7c-2f1d1b3c4d5e')}]})",
    )
    .await;
    assert!(
        matches!(
            &summary.end,
            RunEnd::Failed(DriverError::Server(diagnostics))
                if matches!(diagnostics.code, Some(ServerCode::Mongo { code: REFUSED, .. }))
        ),
        "killSessions gave {:?}",
        summary.end
    );
}

async fn assert_ended_on_the_server(watcher: &dyn EditorSession, marker: &str) {
    let give_up = Instant::now() + test_liveness().cancel_grace;
    loop {
        let left = running(watcher, marker).await;
        if left == Value::Int(0) {
            return;
        }
        assert!(Instant::now() < give_up, "{left:?} operations still run after the stop");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn an_editor_stop_ends_the_statement_when_killsessions_is_refused() {
    let (fixture, collection) = refusing_kill_sessions().await;
    let connection = connect(&fixture).await;
    let (session, watcher) = (editor(connection.as_ref()).await, editor(connection.as_ref()).await);
    assert_kill_sessions_refused(watcher.as_ref()).await;
    let marker = unique("stopped");
    let cancel = CancellationToken::new();

    let statement = async {
        let options = RunOptions::new(cancel.clone());
        let (summary, _) = run_with(session.as_ref(), &slow_find(&collection, &marker), options).await;
        (summary, Instant::now())
    };
    let ((summary, finished), cancelled) =
        tokio::join!(statement, cancel_once_running(watcher.as_ref(), &marker, &cancel));

    assert_eq!(summary.end, RunEnd::Cancelled);
    let after_cancel = finished.saturating_duration_since(cancelled);
    assert!(
        after_cancel < test_liveness().cancel_grace,
        "the run waited out the grace, {after_cancel:?} after its cancel"
    );
    assert_ended_on_the_server(watcher.as_ref(), &marker).await;
    let (again, _) = run(session.as_ref(), "db.runCommand({ping: 1})").await;
    assert_eq!(again.end, RunEnd::Completed, "the session runs again");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn a_workspace_stop_reads_as_cancelled_when_killsessions_is_refused() {
    let (fixture, collection) = refusing_kill_sessions().await;
    let connection = connect(&fixture).await;
    let watcher = editor(connection.as_ref()).await;
    assert_kill_sessions_refused(watcher.as_ref()).await;
    let marker = unique("stopped");
    let cancel = CancellationToken::new();
    let read = ReadStatement::User(UserSql::new(slow_find(&collection, &marker)));
    let options = CallOptions::new(Some(Instant::now() + CALL), cancel.clone());

    let streaming = async {
        let streamed = connection.stream_read(&read, sink(), options).await;
        (streamed, Instant::now())
    };
    let ((streamed, finished), cancelled) =
        tokio::join!(streaming, cancel_once_running(watcher.as_ref(), &marker, &cancel));

    assert!(matches!(streamed, Err(DriverError::Cancelled)), "{streamed:?}");
    let after_cancel = finished.saturating_duration_since(cancelled);
    assert!(
        after_cancel < test_liveness().cancel_grace,
        "the read waited out the grace, {after_cancel:?} after its cancel"
    );
    assert_ended_on_the_server(watcher.as_ref(), &marker).await;
    assert_eq!(connection.link_state(), LinkState::Live);
}

/// How long the sink holds the first rows after it cancels, for the stop
/// to find the cursor waiting between batches.
const HOLD: Duration = Duration::from_millis(300);

/// Cancels the call when the first rows arrive and holds them, as a slow
/// export file does, so no operation runs on the server when the stop
/// comes.
struct CancelAtFirstRows {
    cancel: CancellationToken,
    rows: Arc<AtomicUsize>,
}

#[async_trait]
impl ResultSink for CancelAtFirstRows {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        if let ResultEvent::Rows(rows) = event {
            self.rows.fetch_add(rows.len(), Ordering::SeqCst);
            if !self.cancel.is_cancelled() {
                self.cancel.cancel();
                tokio::time::sleep(HOLD).await;
            }
        }
        SinkFlow::Continue
    }
}

/// How many cursors tagged with `marker` wait on the server between
/// batches.
async fn idle_cursors(watcher: &dyn EditorSession, marker: &str) -> Value {
    let (summary, events) = run(
        watcher,
        &format!(
            "db.getSiblingDB('admin').aggregate([{{$currentOp: {{allUsers: true, idleCursors: true}}}}, \
             {{$match: {{type: 'idleCursor', 'cursor.originatingCommand.comment': '{marker}'}}}}, {{$count: 'n'}}])"
        ),
    )
    .await;
    assert_eq!(summary.end, RunEnd::Completed);
    rows(&events)
        .first()
        .and_then(|row| row.first())
        .cloned()
        .unwrap_or(Value::Int(0))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn a_stop_between_batches_ends_an_export_when_killsessions_is_refused() {
    let (fixture, _) = refusing_kill_sessions().await;
    let collection = unique("wide");
    // About 100 KB a document, so a batch of the server's holds fewer
    // documents than one of the export's and the cursor stays open.
    let filled = fixture
        .shell(&format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertMany(\
             Array.from({{length: 300}}, (_, n) => ({{_id: n, label: 'row ' + n, pad: 'x'.repeat(100000)}}))).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    let connection = connect(&fixture).await;
    let watcher = editor(connection.as_ref()).await;
    let marker = unique("between");
    let cancel = CancellationToken::new();
    let written = Arc::new(AtomicUsize::new(0));
    let sink = CancelAtFirstRows {
        cancel: cancel.clone(),
        rows: written.clone(),
    };
    let read = ReadStatement::User(UserSql::new(format!(
        "db.getCollection('{collection}').find({{}}, {{label: 1, pad: 1}}).comment('{marker}')"
    )));

    let started = Instant::now();
    let streamed = connection
        .stream_read(&read, Box::new(sink), CallOptions::new(None, cancel))
        .await;

    assert!(matches!(streamed, Err(DriverError::Cancelled)), "{streamed:?}");
    assert!(
        started.elapsed() < HOLD + test_liveness().cancel_grace,
        "the export waited out the grace"
    );
    let written = written.load(Ordering::SeqCst);
    assert!(written < 300, "the export wrote all {written} rows past its stop");
    let give_up = Instant::now() + test_liveness().cancel_grace;
    loop {
        let left = idle_cursors(watcher.as_ref(), &marker).await;
        if left == Value::Int(0) {
            break;
        }
        assert!(Instant::now() < give_up, "{left:?} cursors still open after the stop");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(connection.link_state(), LinkState::Live);
}
