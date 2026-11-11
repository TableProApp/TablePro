//! A stop on a server that refuses `killSessions`, as Atlas M0 and Flex
//! do: the `failCommand` fail point refuses it here, and the stop ends the
//! call's operations by id instead.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, DatabaseDriver, DriverError, EditorSession, LinkState, ReadStatement, ResultEvent, ResultSink,
    RowLimit, RunEnd, RunOptions, ServerCode, SinkFlow, TimeoutPhase, UserSql, Value, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_test_fixtures::MongoFixture;
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, DATABASE, connect, editor, first_page, fixture_options, rows, run, run_with, sink, unique, within,
};

/// `CommandNotFound`, what the fail point answers `killSessions` with.
const REFUSED: i32 = 59;

/// How long a statement may take to show on the server.
const REACHED: Duration = Duration::from_secs(5);

/// Set the `failCommand` fail point to `data`, in place of what it held.
async fn fail_commands(fixture: &MongoFixture, data: &str) {
    let set = fixture
        .shell(&format!(
            "db.adminCommand({{configureFailPoint: 'failCommand', mode: 'alwaysOn', data: {{{data}}}}}).ok"
        ))
        .await
        .expect("mongosh ran");
    assert!(
        set.succeeded() && set.stdout_text().trim() == "1",
        "the fail point is not set: {} {}",
        set.stdout_text(),
        set.stderr_text()
    );
}

/// A server whose every `killSessions` fails, and a collection whose
/// documents each take a second of server-side JavaScript to read.
async fn refusing_kill_sessions() -> (MongoFixture, String) {
    let fixture = MongoFixture::start_with_test_commands()
        .await
        .expect("a MongoDB container with test commands");
    fail_commands(
        &fixture,
        &format!("failCommands: ['killSessions'], errorCode: {REFUSED}"),
    )
    .await;
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

/// A collection of 300 documents of about 100 KB each, so a batch of the
/// server's holds fewer documents than one of the export's and the cursor
/// stays open.
async fn wide_collection(fixture: &MongoFixture) -> String {
    let collection = unique("wide");
    let filled = fixture
        .shell(&format!(
            "db.getSiblingDB('{DATABASE}').getCollection('{collection}').insertMany(\
             Array.from({{length: 300}}, (_, n) => ({{_id: n, label: 'row ' + n, pad: 'x'.repeat(100000)}}))).acknowledged"
        ))
        .await
        .expect("mongosh ran");
    assert!(filled.succeeded(), "{}", filled.stderr_text());
    collection
}

fn wide_read(collection: &str, marker: &str) -> ReadStatement {
    ReadStatement::User(UserSql::new(format!(
        "db.getCollection('{collection}').find({{}}, {{label: 1, pad: 1}}).comment('{marker}')"
    )))
}

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

/// Holds the first rows until `until`, past the call's deadline, so the
/// deadline comes while the cursor waits between batches.
struct HoldFirstRows {
    until: Instant,
    rows: Arc<AtomicUsize>,
}

#[async_trait]
impl ResultSink for HoldFirstRows {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        if let ResultEvent::Rows(rows) = event
            && self.rows.fetch_add(rows.len(), Ordering::SeqCst) == 0
        {
            tokio::time::sleep_until(self.until).await;
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

async fn assert_cursors_closed(watcher: &dyn EditorSession, marker: &str) {
    let give_up = Instant::now() + test_liveness().cancel_grace;
    loop {
        let left = idle_cursors(watcher, marker).await;
        if left == Value::Int(0) {
            return;
        }
        assert!(Instant::now() < give_up, "{left:?} cursors still open after the stop");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn a_stop_between_batches_ends_an_export_when_killsessions_is_refused() {
    let (fixture, _) = refusing_kill_sessions().await;
    let collection = wide_collection(&fixture).await;
    let connection = connect(&fixture).await;
    let watcher = editor(connection.as_ref()).await;
    assert_kill_sessions_refused(watcher.as_ref()).await;
    let marker = unique("between");
    let cancel = CancellationToken::new();
    let written = Arc::new(AtomicUsize::new(0));
    let sink = CancelAtFirstRows {
        cancel: cancel.clone(),
        rows: written.clone(),
    };

    let started = Instant::now();
    let streamed = connection
        .stream_read(
            &wide_read(&collection, &marker),
            Box::new(sink),
            CallOptions::new(None, cancel),
        )
        .await;

    assert!(matches!(streamed, Err(DriverError::Cancelled)), "{streamed:?}");
    assert!(
        started.elapsed() < HOLD + test_liveness().cancel_grace,
        "the export waited out the grace"
    );
    let written = written.load(Ordering::SeqCst);
    assert!(written < 300, "the export wrote all {written} rows past its stop");
    assert_cursors_closed(watcher.as_ref(), &marker).await;
    assert_eq!(connection.link_state(), LinkState::Live);
}

/// Longer than the export takes to read its first batch.
const FIRST_BATCH: Duration = Duration::from_secs(2);

/// How long `killSessions` and `currentOp` hold their answer in the
/// deadline test, so the read ends while the fallback waits on
/// `currentOp`.
const BLOCKED: Duration = Duration::from_millis(600);

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn a_deadline_between_batches_ends_an_export_when_killsessions_is_refused() {
    let (fixture, small) = refusing_kill_sessions().await;
    fail_commands(
        &fixture,
        &format!(
            "failCommands: ['killSessions', 'currentOp'], errorCode: {REFUSED}, \
             blockConnection: true, blockTimeMS: {}",
            BLOCKED.as_millis()
        ),
    )
    .await;
    let collection = wide_collection(&fixture).await;
    let mut options = fixture_options(&fixture, WorkspaceSettings::workspace(false));
    // The export's client closes once `currentOp` answers, so the call's
    // grace has room for both blocked commands.
    options.liveness.cancel_grace = 3 * BLOCKED + test_liveness().cancel_grace;
    let connection = MongoDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection");
    let watcher = editor(connection.as_ref()).await;
    assert_kill_sessions_refused(watcher.as_ref()).await;
    let marker = unique("deadline");
    let deadline = Instant::now() + FIRST_BATCH;
    // After the refusal and before `currentOp` answers.
    let released = deadline + BLOCKED + BLOCKED / 2;
    let written = Arc::new(AtomicUsize::new(0));
    let sink = HoldFirstRows {
        until: released,
        rows: written.clone(),
    };

    let streamed = connection
        .stream_read(
            &wide_read(&collection, &marker),
            Box::new(sink),
            CallOptions::new(Some(deadline), CancellationToken::new()),
        )
        .await;

    assert!(
        matches!(
            streamed,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            })
        ),
        "{streamed:?}"
    );
    let after_release = Instant::now().saturating_duration_since(released);
    assert!(
        after_release < test_liveness().cancel_grace,
        "the export waited out the grace, {after_release:?} after the sink gave its rows back"
    );
    let written = written.load(Ordering::SeqCst);
    assert!(
        written > 0 && written < 300,
        "the deadline did not come between batches: {written} rows"
    );
    assert_cursors_closed(watcher.as_ref(), &marker).await;
    assert_eq!(connection.link_state(), LinkState::Live);
    let page = first_page(connection.as_ref(), &TableRef::new(Some(DATABASE.to_owned()), small)).await;
    assert_eq!(page.result.rows.len(), 50, "the connection reads again");
}

/// How long the fail point holds each `getMore`, `killSessions` and
/// `currentOp` in the page test, so each batch after a page's first takes
/// this long, and so does the fallback's `currentOp`.
const HELD: Duration = Duration::from_millis(800);

/// A page whose first batch holds five documents, so the rest take a
/// `getMore` of at most 16 MB each.
fn page_read(collection: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("db.getCollection('{collection}').find({{}}).batchSize(5)"));
    builder.finish()
}

/// Refuse the call's `killSessions`, which the fail point holds, by
/// ending it with `Interrupted`: the fail point has one setting, and
/// `currentOp` has to be held without an error.
async fn refuse_held_kill_sessions(watcher: &dyn EditorSession) -> Instant {
    let give_up = Instant::now() + REACHED;
    loop {
        let (summary, events) = run(
            watcher,
            "db.getSiblingDB('admin').aggregate([{$currentOp: {allUsers: true}}, \
             {$match: {'command.killSessions': {$exists: true}}}, {$project: {_id: 0, opid: 1}}])",
        )
        .await;
        assert_eq!(summary.end, RunEnd::Completed);
        match rows(&events).first().and_then(|row| row.first()) {
            Some(Value::Int(opid)) => {
                let (killed, _) = run(watcher, &format!("db.adminCommand({{killOp: 1, op: {opid}}})")).await;
                assert_eq!(killed.end, RunEnd::Completed);
                return Instant::now();
            }
            other => assert!(other.is_none(), "an opid of {other:?}"),
        }
        assert!(Instant::now() < give_up, "the stop never sent killSessions");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
#[ignore = "requires docker"]
async fn a_deadline_ends_a_page_while_the_fallback_waits_on_currentop() {
    let (fixture, small) = refusing_kill_sessions().await;
    let wide = wide_collection(&fixture).await;
    fail_commands(
        &fixture,
        &format!(
            "failCommands: ['getMore', 'killSessions', 'currentOp'], blockConnection: true, blockTimeMS: {}",
            HELD.as_millis()
        ),
    )
    .await;
    let mut options = fixture_options(&fixture, WorkspaceSettings::workspace(false));
    options.liveness.cancel_grace = 3 * HELD;
    let connection = MongoDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection");
    let watcher = editor(connection.as_ref()).await;
    // The wide page takes two held `getMore`s, and the deadline comes
    // halfway through the second.
    let deadline = Instant::now() + HELD + HELD / 2;

    let page = async {
        let page = connection
            .query_bound(
                &page_read(&wide),
                RowLimit::new(1_000).expect("a limit"),
                CallOptions::new(Some(deadline), CancellationToken::new()),
            )
            .await;
        (page, Instant::now())
    };
    let ((page, finished), refused) = tokio::join!(page, refuse_held_kill_sessions(watcher.as_ref()));

    assert!(
        matches!(
            page,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            })
        ),
        "{:?}",
        page.map(|page| page.rows.len())
    );
    // Before `currentOp` answered, so `settle` found the kill refused.
    assert!(
        finished < refused + HELD,
        "the page waited for the fallback's currentOp, {:?} after the refusal",
        finished.saturating_duration_since(refused)
    );
    assert_eq!(connection.link_state(), LinkState::Live);
    let next = connection
        .query_bound(&page_read(&small), RowLimit::new(30).expect("a limit"), within(CALL))
        .await
        .expect("the next page");
    assert_eq!(next.rows.len(), 30);
    assert_eq!(connection.link_state(), LinkState::Live);
}
