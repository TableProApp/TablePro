use std::cell::{Cell, RefCell};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::column::{ColumnDefault, ColumnType, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::export::CsvOptions;
use tablepro_core::meta::{EngineRowId, RowIdentity, TableRef};
use tablepro_core::{
    ColumnInfo, DriverError, ErrorCategory, FilterSet, ReadOnlyRefusal, ResultEvent, ServerDiagnostics, ServerInfo,
    Truncation, UserSql, Value,
};
use tablepro_session::runtime::CountingHold;
use tablepro_test_support::{ConnectionScript, FakeReply, StreamEnd};

use super::*;
use crate::test_support::{FakeSession, finish_on_main, first_descendant_of_type, wait_until};
use crate::ui::export::{AbortOutcome, ExpectedRows, ExportFormat, ExportOperationsButton, RowFormat, TableExport};
use crate::ui::grid::RowSnapshot;
use crate::workspace::{InhibitTarget, WorkOutcome, answer, visible_alert};

const WAIT: Duration = Duration::from_secs(20);

/// Hands out cookies, and keeps the ones still held.
#[derive(Clone, Default)]
struct Session {
    held: Rc<RefCell<Vec<(u32, gtk::ApplicationInhibitFlags)>>>,
    next: Rc<Cell<u32>>,
}

impl InhibitTarget for Session {
    fn inhibit(&self, flags: gtk::ApplicationInhibitFlags, _reason: &str) -> u32 {
        self.next.set(self.next.get() + 1);
        self.held.borrow_mut().push((self.next.get(), flags));
        self.next.get()
    }

    fn uninhibit(&self, cookie: u32) {
        self.held.borrow_mut().retain(|(held, _)| *held != cookie);
    }
}

struct Harness {
    window: adw::Window,
    ledger: Rc<ExportLedger>,
    session: Session,
    hold: Rc<CountingHold>,
    dir: tempfile::TempDir,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Harness {
    fn new() -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_enable_animations(false);
        }
        let window = adw::Window::new();
        let toasts = adw::ToastOverlay::new();
        window.set_content(Some(&toasts));
        window.present();
        let runtime = crate::test_support::test_runtime();
        let session = Session::default();
        let hold = Rc::new(CountingHold::new());
        let ledger = ExportLedger::new(ExportLedgerInit {
            tasks: runtime.tasks(),
            hold: hold.clone(),
            reporter: ExportReporter::new(&window, &toasts),
            inhibitor: WindowInhibitor::new(session.clone()),
        });
        Self {
            window,
            ledger,
            session,
            hold,
            dir: tempfile::tempdir().expect("tempdir"),
            runtime: Some(runtime),
        }
    }

    fn path(&self, name: &str) -> std::path::PathBuf {
        self.dir.path().join(name)
    }

    /// A session whose reads stream `events`.
    fn session(&self, events: FakeReply<Vec<ResultEvent>>, dialect: Option<Arc<dyn SqlDialect>>) -> FakeSession {
        self.scripted(events, |script| {
            if let Some(dialect) = dialect {
                script.dialect = dialect;
            }
        })
    }

    fn scripted(&self, events: FakeReply<Vec<ResultEvent>>, adjust: impl FnOnce(&mut ConnectionScript)) -> FakeSession {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        script.stream_read.always(events);
        adjust(&mut script);
        let tasks = self.runtime.as_ref().expect("the runtime").tasks();
        FakeSession::start(script, [], tasks)
    }

    fn finish(&self, handle: ExportJobHandle) -> ExportOutcome {
        finish_on_main(WAIT, handle.outcome())
            .expect("the export to end")
            .expect("an outcome")
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.window.close();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

fn job(path: &Path, count: usize) -> ExportJob {
    let columns: Arc<[ResultColumn]> = ["id", "name", "note"]
        .iter()
        .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
        .collect();
    let rows = (0..count)
        .map(|row| {
            RowSnapshot::new(
                vec![
                    Value::Int(row as i64),
                    Value::Text(format!("name {row}")),
                    Value::Text("a note of some length".to_owned()),
                ]
                .into(),
                Vec::new(),
            )
        })
        .collect();
    ExportJob {
        destination: gio::File::for_path(path),
        format: ExportFormat::Rows(RowFormat::Csv(CsvOptions::default())),
        source: ExportSource::Rows { columns, rows },
        expected_rows: Some(ExpectedRows::Exact(count as u64)),
        tab: None,
    }
}

fn table_column(name: &str, primary_key: bool) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: ColumnType::untyped_text("text"),
        nullable: !primary_key,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn users(identity: RowIdentity) -> ExportQuery {
    ExportQuery::Table(TableExport {
        table: TableRef::new(None, "users"),
        columns: vec![table_column("id", true), table_column("name", false)].into(),
        filter: FilterSet::default(),
        sort: Vec::new(),
        identity,
    })
}

fn by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }
}

fn started(names: &[&str]) -> ResultEvent {
    ResultEvent::ResultSetStarted {
        columns: names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect(),
    }
}

fn finished(rows: u64) -> ResultEvent {
    ResultEvent::ResultSetFinished {
        retained: rows,
        total_rows: Some(rows),
        truncation: Truncation::Complete,
    }
}

/// `batches` batches of `size` rows each, numbered from zero.
fn streamed(batches: usize, size: usize) -> Vec<ResultEvent> {
    let mut events = vec![started(&["id", "name"])];
    for batch in 0..batches {
        let rows = (0..size)
            .map(|row| {
                let id = (batch * size + row) as i64;
                vec![Value::Int(id), Value::Text(format!("user {id}"))]
            })
            .collect();
        events.push(ResultEvent::Rows(rows));
    }
    events.push(finished((batches * size) as u64));
    events
}

fn read_job(path: &Path, session: &FakeSession, query: ExportQuery) -> ExportJob {
    ExportJob {
        destination: gio::File::for_path(path),
        format: ExportFormat::Rows(RowFormat::Csv(CsvOptions::default())),
        source: ExportSource::Query {
            session: session.session.clone(),
            query,
        },
        expected_rows: None,
        tab: None,
    }
}

#[gtk4::test]
fn entire_table_export_streams_every_row() {
    let harness = Harness::new();
    let path = harness.path("users.csv");
    let fake = harness.session(FakeReply::ok(streamed(100, 250)), None);

    let outcome = harness.finish(
        harness
            .ledger
            .begin(read_job(&path, &fake, users(by_id())))
            .expect("started"),
    );

    assert!(
        matches!(outcome, ExportOutcome::Exported { rows: 25_000 }),
        "{outcome:?}"
    );
    let text = std::fs::read_to_string(&path).expect("the export");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 25_001);
    assert_eq!(lines[0], "\"id\",\"name\"");
    assert_eq!(lines[25_000], "\"24999\",\"user 24999\"");
    assert_eq!(
        fake.connection.observed_deadlines("stream_read"),
        [None],
        "an export ran under a deadline"
    );
}

#[gtk4::test]
fn entire_table_export_has_no_identity_columns() {
    let harness = Harness::new();
    let path = harness.path("users.csv");
    let dialect: Arc<dyn SqlDialect> = Arc::new(drivers_postgres::PgDialect::new(&ServerInfo::new(
        "PostgreSQL",
        "16.4",
        16,
        4,
        0,
    )));
    let fake = harness.session(FakeReply::ok(streamed(1, 2)), Some(dialect));
    let identity = RowIdentity::EngineRowId(EngineRowId::PostgresCtid);

    let outcome = harness.finish(
        harness
            .ledger
            .begin(read_job(&path, &fake, users(identity)))
            .expect("started"),
    );

    assert!(matches!(outcome, ExportOutcome::Exported { rows: 2 }), "{outcome:?}");
    let sql = fake.connection.observed_sql("stream_read");
    let [Some(sql)] = sql.as_slice() else {
        panic!("one read, not {sql:?}");
    };
    let projection = sql
        .strip_prefix("SELECT ")
        .and_then(|rest| rest.split_once(" FROM "))
        .map(|(projection, _)| projection)
        .expect("a projection");
    assert!(!projection.contains("ctid"), "the row id was projected: {sql}");
    let projected: Vec<&str> = projection.split(", ").collect();
    assert_eq!(projected.len(), 2, "{sql}");
    assert!(
        projected[0].ends_with(r#""id""#) && projected[1].ends_with(r#""name""#),
        "{sql}"
    );
    let text = std::fs::read_to_string(&path).expect("the export");
    assert_eq!(text.lines().next(), Some("\"id\",\"name\""));
}

#[gtk4::test]
fn stopping_entire_table_export_cancels_stream() {
    let harness = Harness::new();
    let path = harness.path("users.csv");
    std::fs::write(&path, "old").expect("the existing file");
    let fake = harness.session(FakeReply::UntilStopped, None);
    let handle = harness
        .ledger
        .begin(read_job(&path, &fake, users(by_id())))
        .expect("started");
    wait_until(WAIT, || fake.connection.observed_cancels("stream_read").len() == 1).expect("the read to start");

    harness.ledger.cancel_all();
    let outcome = harness.finish(handle);

    assert!(
        matches!(outcome, ExportOutcome::Stopped(AbortOutcome::Untouched)),
        "{outcome:?}"
    );
    let cancel = fake.connection.observed_cancels("stream_read").remove(0);
    wait_until(WAIT, || cancel.is_cancelled()).expect("the stop to reach the read");
    assert_eq!(std::fs::read_to_string(&path).expect("the file"), "old");
}

#[gtk4::test]
fn editor_all_rows_export_uses_user_sql_read() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let fake = harness.session(FakeReply::ok(streamed(1, 3)), None);
    let statement = "SELECT id, name FROM users WHERE id < 3";
    let query = ExportQuery::Editor {
        sql: UserSql::new(statement),
    };

    let outcome = harness.finish(harness.ledger.begin(read_job(&path, &fake, query)).expect("started"));

    assert!(matches!(outcome, ExportOutcome::Exported { rows: 3 }), "{outcome:?}");
    assert_eq!(
        fake.connection.observed_sql("stream_read"),
        [Some(statement.to_owned())]
    );
    assert_eq!(fake.connection.observed_deadlines("stream_read"), [None]);
}

#[gtk4::test]
fn editor_all_rows_multiple_result_sets_presents_alert() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let mut events = streamed(1, 3);
    events.extend(streamed(1, 1));
    let fake = harness.session(FakeReply::ok(events), None);
    let query = ExportQuery::Editor {
        sql: UserSql::new("SELECT 1; SELECT 2"),
    };

    let outcome = harness.finish(harness.ledger.begin(read_job(&path, &fake, query)).expect("started"));

    assert!(
        matches!(
            outcome,
            ExportOutcome::Failed {
                failure: ExportFailure::Stream(ExportStreamFailure::MultipleResultSets),
                file: Some(AbortOutcome::Removed),
            }
        ),
        "{outcome:?}"
    );
    wait_until(WAIT, || visible_alert(&harness.window).is_some()).expect("the alert");
    let alert = visible_alert(&harness.window).expect("the alert");
    assert_eq!(alert.heading().as_deref(), Some("Couldn't Export"));
    assert!(alert.body().contains("more than one result"), "{}", alert.body());
    assert!(!path.exists(), "the failed export left its file");
}

#[gtk4::test]
fn a_second_result_set_fails_the_export_when_the_read_ends_ok() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let mut events = streamed(1, 3);
    events.extend(streamed(1, 1));
    let fake = harness.scripted(FakeReply::ok(events), |script| {
        script.stream_end = StreamEnd::SummaryWhenStopped;
    });
    let query = ExportQuery::Editor {
        sql: UserSql::new("SELECT * FROM a; SELECT * FROM b"),
    };

    let outcome = harness.finish(harness.ledger.begin(read_job(&path, &fake, query)).expect("started"));

    assert!(
        matches!(
            outcome,
            ExportOutcome::Failed {
                failure: ExportFailure::Stream(ExportStreamFailure::MultipleResultSets),
                file: Some(AbortOutcome::Removed),
            }
        ),
        "{outcome:?}"
    );
    assert!(!path.exists(), "the first result's rows were kept as the export");
}

#[gtk4::test]
fn a_read_that_fails_after_its_rows_removes_the_file() {
    let harness = Harness::new();
    let path = harness.path("users.csv");
    let failure = DriverError::Server(Box::new(ServerDiagnostics::new(None, "division by zero")));
    let fake = harness.scripted(FakeReply::ok(streamed(1, 3)), |script| {
        script.stream_end = StreamEnd::Failed(failure);
    });

    let outcome = harness.finish(
        harness
            .ledger
            .begin(read_job(&path, &fake, users(by_id())))
            .expect("started"),
    );

    let ExportOutcome::Failed {
        failure: ExportFailure::Table(error),
        file: Some(AbortOutcome::Removed),
    } = &outcome
    else {
        panic!("{outcome:?}");
    };
    assert_eq!(error.category(), Some(ErrorCategory::Server));
    assert!(!path.exists(), "the failed read left its file");
}

#[gtk4::test]
fn a_statement_with_no_result_set_says_it_returned_no_rows() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let fake = harness.session(FakeReply::ok(Vec::new()), None);
    let query = ExportQuery::Editor {
        sql: UserSql::new("SET search_path TO app"),
    };

    let outcome = harness.finish(harness.ledger.begin(read_job(&path, &fake, query)).expect("started"));

    assert!(
        matches!(
            outcome,
            ExportOutcome::Failed {
                failure: ExportFailure::Stream(ExportStreamFailure::NoResultSet),
                file: Some(AbortOutcome::Removed),
            }
        ),
        "{outcome:?}"
    );
    wait_until(WAIT, || visible_alert(&harness.window).is_some()).expect("the alert");
    let body = visible_alert(&harness.window).expect("the alert").body();
    assert!(body.contains("returned no rows to export"), "{body}");
    assert!(!path.exists(), "the empty export left its file");
}

#[gtk4::test]
fn a_rerun_refused_as_a_write_says_export_all_only_reads() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let refused = DriverError::ReadOnly(ReadOnlyRefusal::server(ServerDiagnostics::new(
        None,
        "cannot execute INSERT in a read-only transaction",
    )));
    let fake = harness.session(FakeReply::err(refused), None);
    let query = ExportQuery::Editor {
        sql: UserSql::new("INSERT INTO t VALUES (1) RETURNING *"),
    };

    let outcome = harness.finish(harness.ledger.begin(read_job(&path, &fake, query)).expect("started"));

    let ExportOutcome::Failed {
        failure: ExportFailure::Statement(error),
        ..
    } = &outcome
    else {
        panic!("{outcome:?}");
    };
    assert_eq!(error.category(), Some(ErrorCategory::ReadOnly));
    wait_until(WAIT, || visible_alert(&harness.window).is_some()).expect("the alert");
    let body = visible_alert(&harness.window).expect("the alert").body();
    assert!(
        body.starts_with("Export All only runs statements that read data."),
        "{body}"
    );
}

#[gtk4::test]
fn snapshot_export_of_10k_rows_keeps_main_loop_responsive() {
    let harness = Harness::new();
    let path = harness.path("rows.csv");
    let ticks = Rc::new(Cell::new(0_u32));
    let counted = ticks.clone();
    let ticking = glib::timeout_add_local(Duration::from_millis(1), move || {
        counted.set(counted.get() + 1);
        glib::ControlFlow::Continue
    });

    let handle = harness.ledger.begin(job(&path, 10_000)).expect("started");
    let outcome = harness.finish(handle);
    ticking.remove();

    assert!(
        matches!(outcome, ExportOutcome::Exported { rows: 10_000 }),
        "{outcome:?}"
    );
    assert!(ticks.get() > 0, "the main loop never ran while the export did");
    let text = std::fs::read_to_string(&path).expect("the export");
    assert_eq!(text.lines().count(), 10_001);
    assert!(
        text.starts_with("\"id\",\"name\",\"note\"\n\"0\",\"name 0\""),
        "{}",
        &text[..40]
    );
    assert_eq!(harness.ledger.in_flight(), 0);
    assert_eq!(harness.hold.live(), 0, "the export kept the process held");
}

#[gtk4::test]
fn stop_button_cancels_job_and_removes_row() {
    let harness = Harness::new();
    let path = harness.path("stopped.csv");
    let button = ExportOperationsButton::default();
    button.bind(&harness.ledger.jobs());
    assert!(!button.is_visible(), "the button showed with nothing running");

    let handle = harness.ledger.begin(job(&path, 10_000)).expect("started");
    assert!(button.is_visible());
    let row = button.job_list().row_at_index(0).expect("the job's row");
    let stop = first_descendant_of_type::<gtk::Button>(&row).expect("the stop button");
    stop.emit_clicked();
    let outcome = harness.finish(handle);

    assert!(
        matches!(outcome, ExportOutcome::Stopped(AbortOutcome::Removed)),
        "{outcome:?}"
    );
    assert!(button.job_list().row_at_index(0).is_none(), "the row stayed");
    assert!(!button.is_visible(), "the button stayed with nothing running");
    assert!(!path.exists(), "the stopped export left its file");
}

#[gtk4::test]
fn ledger_holds_inhibit_cookie_while_exporting() {
    let harness = Harness::new();
    assert!(!harness.ledger.is_inhibiting());

    let handle = harness
        .ledger
        .begin(job(&harness.path("held.csv"), 100))
        .expect("started");
    assert!(harness.ledger.is_inhibiting());
    assert_eq!(
        harness.session.held.borrow().as_slice(),
        [(
            1,
            gtk::ApplicationInhibitFlags::LOGOUT | gtk::ApplicationInhibitFlags::SUSPEND
        )]
    );
    assert_eq!(harness.hold.live(), 1);
    harness.finish(handle);

    assert!(!harness.ledger.is_inhibiting());
    assert!(harness.session.held.borrow().is_empty(), "the cookie was kept");
    assert_eq!(harness.hold.live(), 0);
}

#[gtk4::test]
fn close_blocker_reports_running_exports_and_stop_waits_for_idle() {
    let harness = Harness::new();
    assert_eq!(harness.ledger.blocking(), None);

    let handle = harness
        .ledger
        .begin(job(&harness.path("blocked.csv"), 10_000))
        .expect("started");
    let prompt = harness.ledger.blocking().expect("a running export blocks the close");
    assert_eq!(prompt.heading, "Stop Exports?");
    assert!(prompt.body.starts_with("1 export is still running"), "{}", prompt.body);
    let stopping = harness.ledger.stop();
    finish_on_main(WAIT, stopping).expect("the stop to settle");

    assert_eq!(harness.ledger.in_flight(), 0);
    assert_eq!(harness.ledger.blocking(), None);
    let outcome = harness.finish(handle);
    assert!(matches!(outcome, ExportOutcome::Stopped(_)), "{outcome:?}");
}

#[gtk4::test]
fn a_tab_hears_how_its_export_ended_once_it_settled() {
    let harness = Harness::new();
    let heard = Rc::new(RefCell::new(Vec::new()));
    let (log, ledger) = (heard.clone(), Rc::downgrade(&harness.ledger));
    harness.ledger.on_ended(move |tab, outcome| {
        let running = ledger.upgrade().map(|ledger| ledger.in_flight());
        log.borrow_mut().push((tab, outcome, running));
    });
    let (finished, failed, stopped) = (uuid::Uuid::new_v4(), uuid::Uuid::new_v4(), uuid::Uuid::new_v4());
    let from = |job: ExportJob, tab| ExportJob { tab: Some(tab), ..job };

    harness.finish(
        harness
            .ledger
            .begin(from(job(&harness.path("rows.csv"), 10), finished))
            .expect("started"),
    );
    harness.finish(
        harness
            .ledger
            .begin(from(job(&harness.path("missing").join("rows.csv"), 10), failed))
            .expect("started"),
    );
    let fake = harness.session(FakeReply::UntilStopped, None);
    let stopping = harness
        .ledger
        .begin(from(
            read_job(&harness.path("users.csv"), &fake, users(by_id())),
            stopped,
        ))
        .expect("started");
    wait_until(WAIT, || fake.connection.observed_cancels("stream_read").len() == 1).expect("the read to start");
    harness.ledger.cancel_all();
    harness.finish(stopping);
    harness.finish(
        harness
            .ledger
            .begin(job(&harness.path("untold.csv"), 10))
            .expect("started"),
    );

    assert_eq!(
        *heard.borrow(),
        [
            (finished, WorkOutcome::Succeeded, Some(0)),
            (failed, WorkOutcome::Failed, Some(0)),
            (stopped, WorkOutcome::Cancelled, Some(0)),
        ],
        "a job with no tab was told, or one was told before it settled"
    );
}

#[gtk4::test]
fn failed_export_presents_alert() {
    let harness = Harness::new();
    let path = harness.path("missing").join("rows.csv");

    let outcome = harness.finish(harness.ledger.begin(job(&path, 10)).expect("started"));

    assert!(
        matches!(
            &outcome,
            ExportOutcome::Failed {
                failure: ExportFailure::File(error),
                file: None,
            } if error.matches(gio::IOErrorEnum::NotFound)
        ),
        "{outcome:?}"
    );
    wait_until(WAIT, || visible_alert(&harness.window).is_some()).expect("the alert");
    let alert = visible_alert(&harness.window).expect("the alert");
    assert_eq!(alert.heading().as_deref(), Some("Couldn't Export"));
    assert!(alert.body().contains("rows.csv"), "{}", alert.body());
}

#[gtk4::test]
fn a_window_close_asks_to_stop_running_exports() {
    let test = crate::ui::session_window::tests::TestWindow::connected("ExportClose");
    let exports = test.workspace().exports().expect("the workspace's exports");
    let path = test.dir().join("closing.csv");
    let _running = exports.begin(job(&path, 10_000)).expect("started");

    test.window.close();
    wait_until(WAIT, || {
        visible_alert(&test.window).is_some_and(|alert| alert.heading().as_deref() == Some("Stop Exports?"))
    })
    .expect("the close to ask about the export");
    assert!(answer(&test.window, "stop"));

    wait_until(WAIT, || !test.window.is_visible()).expect("the window to close once the export stopped");
    assert_eq!(exports.in_flight(), 0);
}

#[gtk4::test]
fn a_shut_down_ledger_refuses_new_exports() {
    let harness = Harness::new();
    let path = harness.path("late.csv");

    harness.ledger.shut_down();
    let refused = harness.ledger.begin(job(&path, 10));
    crate::test_support::drain_main_context();

    assert!(refused.is_none(), "an export began after the shutdown");
    assert_eq!(harness.ledger.in_flight(), 0);
    assert_eq!(harness.hold.live(), 0);
    assert!(!path.exists(), "the refused export made its file");
}

#[gtk4::test]
fn a_new_file_shows_under_its_display_name() {
    use std::os::unix::ffi::OsStrExt;

    let harness = Harness::new();
    // Not UTF-8, so the name GIO shows differs from the bytes on disk.
    let path = harness.dir.path().join(std::ffi::OsStr::from_bytes(b"caf\xe9.csv"));
    let handle = harness.ledger.begin(job(&path, 10)).expect("started");
    let item = harness
        .ledger
        .jobs()
        .item(0)
        .and_downcast::<ExportJobItem>()
        .expect("the job's row");

    let outcome = harness.finish(handle);

    assert!(matches!(outcome, ExportOutcome::Exported { rows: 10 }), "{outcome:?}");
    assert!(item.title().ends_with("(invalid encoding)"), "{}", item.title());
}
