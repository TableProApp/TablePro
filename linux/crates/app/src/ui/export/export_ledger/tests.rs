use std::cell::{Cell, RefCell};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::export::CsvOptions;
use tablepro_session::runtime::CountingHold;

use super::*;
use crate::test_support::{finish_on_main, first_descendant_of_type, wait_until};
use crate::ui::export::{AbortOutcome, ExpectedRows, ExportOperationsButton, RowFormat};
use crate::ui::grid::RowSnapshot;
use crate::workspace::{InhibitTarget, answer, visible_alert};

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
    }
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
