use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

use relm4::adw::prelude::*;
use relm4::{Component, ComponentController, Controller};
use relm4::{adw, gtk};
use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DriverError, Environment, ExecResult, OperationControl, QueryResult,
    QueryResultBatch, TableInfo, Value,
};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::{SqlEditor, SqlEditorInit, SqlEditorInput};
use crate::services::database_service::{ConnectionMetadata, DatabaseService, ReconnectParams};

struct PendingQuery {
    dedicated_session: bool,
    token: CancellationToken,
    parameters: Vec<Value>,
    release: oneshot::Sender<Result<QueryResultBatch, DriverError>>,
}

struct HeldConnection {
    open_wait: Arc<std::sync::Mutex<Option<oneshot::Receiver<()>>>>,
    calls: Arc<AtomicUsize>,
    requests: mpsc::Sender<PendingQuery>,
}

#[async_trait::async_trait]
impl Connection for HeldConnection {
    async fn query_result_sets_controlled(
        &self,
        _sql: &str,
        parameters: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        let (release, wait) = oneshot::channel();
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.requests
            .send(PendingQuery {
                dedicated_session: false,
                token: control.cancellation_token().clone(),
                parameters: parameters.to_vec(),
                release,
            })
            .unwrap();
        wait.await.unwrap()
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        let wait = self.open_wait.lock().unwrap().take();
        if let Some(wait) = wait {
            wait.await.unwrap();
        }
        Ok(Box::new(HeldSession {
            calls: self.calls.clone(),
            requests: self.requests.clone(),
        }))
    }

    fn supports_server_cancellation(&self) -> bool {
        true
    }

    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        _table: &str,
        _offset: u64,
        _limit: u64,
    ) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("browse".into()))
    }

    async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("uncontrolled query".into()))
    }

    async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("execute".into()))
    }

    async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("execute".into()))
    }

    async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::Unsupported("transaction".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct HeldSession {
    calls: Arc<AtomicUsize>,
    requests: mpsc::Sender<PendingQuery>,
}

#[async_trait::async_trait]
impl tablepro_core::Session for HeldSession {
    async fn query_params_controlled(
        &mut self,
        _sql: &str,
        parameters: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let (release, wait) = oneshot::channel();
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.requests
            .send(PendingQuery {
                dedicated_session: true,
                token: control.cancellation_token().clone(),
                parameters: parameters.to_vec(),
                release,
            })
            .unwrap();
        Ok(wait.await.unwrap()?.result_sets.remove(0))
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct EditorFixture {
    open_wait: Arc<std::sync::Mutex<Option<oneshot::Receiver<()>>>>,
    controller: Controller<SqlEditor>,
    database: Arc<DatabaseService>,
    connection_id: Uuid,
    calls: Arc<AtomicUsize>,
    requests: mpsc::Receiver<PendingQuery>,
    _runtime: tokio::runtime::Runtime,
}

impl EditorFixture {
    fn new() -> Self {
        adw::init().unwrap();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let _entered = runtime.enter();
        let database = Arc::new(DatabaseService::new_isolated());
        let connection_id = Uuid::new_v4();
        let (requests, incoming) = mpsc::channel();
        let calls = Arc::new(AtomicUsize::new(0));
        let open_wait = Arc::new(std::sync::Mutex::new(None));
        assert!(database.activate(
            connection_id,
            ConnectionMetadata {
                id: connection_id,
                name: "editor dispatch fixture".into(),
                driver_id: "sqlite".into(),
                environment: Environment::Local,
                read_only: false,
                server_version: None,
                query_timeout_secs: None,
            },
            Box::new(HeldConnection {
                open_wait: open_wait.clone(),
                calls: calls.clone(),
                requests
            }),
            None,
            false,
            ReconnectParams {
                driver: Arc::new(drivers_sqlite::SqliteDriver),
                opts: ConnectOptions::default(),
                ssh: None,
                environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Refuse),
            },
        ));
        let controller = SqlEditor::builder()
            .launch(SqlEditorInit {
                schema_index: Default::default(),
                initial_query: Some("SELECT 1;".into()),
                connection_id: Some(connection_id),
                history: None,
                database: database.clone(),
                preferences: crate::services::preferences::PreferencesStore::new(),
            })
            .detach();
        drop(_entered);
        Self {
            open_wait,
            controller,
            database,
            connection_id,
            calls,
            requests: incoming,
            _runtime: runtime,
        }
    }

    fn next_query(&self) -> PendingQuery {
        let mut pending = None;
        spin_until(|| {
            pending = self.requests.try_recv().ok();
            pending.is_some()
        });
        pending.unwrap()
    }

    fn shortcut(&self, trigger: &str, secondary: bool) {
        let model = self.controller.model();
        let view = if secondary {
            model.split_view.secondary_view()
        } else {
            &model.source_view
        };
        let wanted = crate::ui::shortcut::parse(trigger).to_str();
        let controllers = view.observe_controllers();
        for index in 0..controllers.n_items() {
            let Some(controller) = controllers.item(index).and_downcast::<gtk::ShortcutController>() else {
                continue;
            };
            for item in 0..controller.n_items() {
                let shortcut = controller.item(item).and_downcast::<gtk::Shortcut>().unwrap();
                if shortcut.trigger().unwrap().to_str() == wanted {
                    assert!(
                        shortcut
                            .action()
                            .unwrap()
                            .activate(gtk::ShortcutActionFlags::empty(), view, None)
                    );
                    return;
                }
            }
        }
        panic!("installed editor shortcut was not found");
    }

    fn process_inputs(&self) {
        let visible = !self.controller.model().split_view.secondary_view().is_visible();
        self.controller
            .sender()
            .send(SqlEditorInput::SplitToggled(visible))
            .unwrap();
        spin_until(|| self.controller.model().split_view.secondary_view().is_visible() == visible);
    }

    fn finish(&self, query: PendingQuery, result: Result<QueryResultBatch, DriverError>) {
        query.release.send(result).unwrap();
        spin_until(|| self.controller.model().run_button.is_sensitive());
    }
}

impl Drop for EditorFixture {
    fn drop(&mut self) {
        self.database.close(self.connection_id);
    }
}

fn spin_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let context = gtk::glib::MainContext::default();
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "editor did not complete the expected transition"
        );
        context.iteration(false);
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn success() -> Result<QueryResultBatch, DriverError> {
    Ok(QueryResultBatch::single(QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated: false,
    }))
}

fn parameter_response() -> SqlEditorInput {
    SqlEditorInput::RunWithParameters {
        sql: "SELECT :value;".into(),
        planned: super::PlannedStatements {
            statements: vec!["SELECT :value;".into()],
            error_policy: tablepro_core::sql_syntax::script::BatchErrorPolicy::StopScript,
            settings_check: None,
        },
        values: [("value".into(), Value::Int(2))].into(),
    }
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn editor_waits_for_its_session_before_accepting_any_run_input() {
    let fixture = EditorFixture::new();
    let (release, wait) = oneshot::channel();
    fixture.open_wait.lock().unwrap().replace(wait);
    fixture.controller.model().session_button.set_active(true);
    spin_until(|| fixture.controller.model().session_open_in_flight);
    assert!(!fixture.controller.model().run_button.is_sensitive());
    for secondary in [false, true] {
        fixture.shortcut("<Primary>Return", secondary);
        fixture.shortcut("<Primary><Shift>Return", secondary);
    }
    fixture.controller.sender().send(parameter_response()).unwrap();
    fixture.process_inputs();
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 0);
    assert!(fixture.requests.try_recv().is_err());
    release.send(()).unwrap();
    spin_until(|| fixture.controller.model().session.is_some() && fixture.controller.model().run_button.is_sensitive());
    fixture.shortcut("<Primary>Return", false);
    let running = fixture.next_query();
    assert!(running.dedicated_session);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    fixture.finish(running, success());
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn editor_inputs_cannot_dispatch_or_cancel_an_active_query() {
    let fixture = EditorFixture::new();
    fixture.controller.model().run_button.emit_clicked();
    let running = fixture.next_query();
    for secondary in [false, true] {
        fixture.shortcut("<Primary>Return", secondary);
        fixture.shortcut("<Primary><Shift>Return", secondary);
    }
    fixture.controller.sender().send(parameter_response()).unwrap();
    fixture.process_inputs();
    assert!(!running.token.is_cancelled());
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    assert!(fixture.requests.try_recv().is_err());
    fixture.finish(running, success());
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn editor_dispatch_resumes_after_success_cancel_and_timeout() {
    let fixture = EditorFixture::new();
    for (count, result) in [success(), Err(DriverError::Cancelled), Err(DriverError::TimedOut)]
        .into_iter()
        .enumerate()
    {
        fixture.shortcut("<Primary>Return", false);
        let running = fixture.next_query();
        assert_eq!(fixture.calls.load(Ordering::SeqCst), count + 1);
        if matches!(&result, Err(DriverError::Cancelled)) {
            fixture.controller.sender().send(SqlEditorInput::Cancel).unwrap();
            fixture.process_inputs();
            assert!(running.token.is_cancelled());
            fixture.shortcut("<Primary><Shift>Return", false);
            fixture.process_inputs();
            assert_eq!(fixture.calls.load(Ordering::SeqCst), count + 1);
            assert!(!fixture.controller.model().run_button.is_sensitive());
        }
        fixture.finish(running, result);
    }
    fixture.controller.sender().send(parameter_response()).unwrap();
    let parameterized = fixture.next_query();
    assert_eq!(parameterized.parameters, [Value::Int(2)]);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 4);
    fixture.finish(parameterized, success());
}

fn exposed_toolbar(fixture: &EditorFixture) -> ([gtk::Button; 3], [gtk::Widget; 2]) {
    let model = fixture.controller.model();
    model.cancel_button.set_visible(true);
    model.running_spinner.set_visible(true);
    model.longer_timeout_button.set_label("Run again with a longer timeout");
    model.longer_timeout_button.set_visible(true);
    model.status.set_label("Received 1000000 rows");
    let secondary = model.pin_button.parent().unwrap();
    secondary
        .observe_children()
        .iter::<gtk::glib::Object>()
        .flatten()
        .filter_map(|child| child.downcast::<gtk::MenuButton>().ok())
        .next()
        .unwrap()
        .set_visible(true);
    (
        [
            model.run_button.clone(),
            model.cancel_button.clone(),
            model.longer_timeout_button.clone(),
        ],
        [model.run_button.parent().unwrap(), secondary],
    )
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn editor_actions_fit_narrow_rows_with_running_and_retry_controls() {
    let fixture = EditorFixture::new();
    let root = fixture.controller.widget();
    let (buttons, bars) = exposed_toolbar(&fixture);
    assert!(root.measure(gtk::Orientation::Horizontal, -1).0 <= 600);
    let window = gtk::Window::builder()
        .default_width(630)
        .default_height(700)
        .child(root)
        .build();
    window.present();
    let css = gtk::CssProvider::new();
    for widget in [bars[0].clone(), bars[1].clone(), buttons[2].clone().upcast()] {
        widget.add_css_class("resource-toolbar");
    }
    gtk::style_context_add_provider_for_display(&root.display(), &css, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    for style in ["", ".resource-toolbar { font-size: 20px; }"] {
        css.load_from_string(style);
        for width in [630, 600, 910] {
            window.set_default_size(width, 700);
            let ready = std::rc::Rc::new(std::cell::Cell::new(false));
            let observed = ready.clone();
            let frames = std::cell::Cell::new(0);
            window.add_tick_callback(move |_, _| {
                frames.set(frames.get() + 1);
                if frames.get() < 2 {
                    return gtk::glib::ControlFlow::Continue;
                }
                observed.set(true);
                gtk::glib::ControlFlow::Break
            });
            spin_until(|| ready.get() && root.width() > 0 && buttons.iter().all(|button| button.width() > 0));
            assert!(root.width() <= width);
            for bar in &bars {
                assert!(bar.measure(gtk::Orientation::Horizontal, -1).0 <= root.width());
            }
            for button in &buttons {
                let bounds = button.compute_bounds(root).unwrap();
                assert!(bounds.x() >= 0.0 && bounds.y() >= 0.0);
                assert!(
                    bounds.x() + bounds.width() <= root.width() as f32 + 0.5,
                    "button={} requested={width} actual={} style={style} bounds={bounds:?}",
                    button.label().unwrap_or_default(),
                    root.width()
                );
                assert!(bounds.y() + bounds.height() <= root.height() as f32 + 0.5);
                assert!(button.is_visible());
            }
            assert!(fixture.controller.model().source_view.height() > 0);
        }
    }
    gtk::style_context_remove_provider_for_display(&root.display(), &css);
    window.close();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn dropping_an_editor_releases_its_source_view_and_buffer() {
    adw::init().unwrap();
    let native = sourceview5::View::new();
    native.set_im_module(Some("simple"));
    let native_weak = native.downgrade();
    drop(native);
    spin_until(|| native_weak.upgrade().is_none());
    let mut fixture = EditorFixture::new();
    fixture.controller.model().source_view.set_im_module(Some("simple"));
    fixture
        .controller
        .model()
        .split_view
        .secondary_view()
        .set_im_module(Some("simple"));
    let _runtime = std::mem::replace(&mut fixture._runtime, tokio::runtime::Runtime::new().unwrap());
    let root = fixture.controller.widget().downgrade();
    let view = fixture.controller.model().source_view.downgrade();
    let buffer = fixture.controller.model().source_view.buffer().downgrade();
    drop(fixture);
    let deadline = Instant::now() + Duration::from_secs(1);
    let context = gtk::glib::MainContext::default();
    while Instant::now() < deadline {
        context.iteration(false);
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(root.upgrade().is_none(), "editor root remains alive");
    assert!(view.upgrade().is_none(), "editor view remains alive");
    assert!(buffer.upgrade().is_none(), "editor buffer remains alive");
}
