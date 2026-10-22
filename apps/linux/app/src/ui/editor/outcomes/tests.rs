use super::super::session_mode::StatementTarget;
use super::super::stream_pages::{StreamTerminal, StreamedResult};
use super::{
    BatchErrorPolicy, ScriptRunResult, StatementIdentity, StatementOutcomeKind, StatementRun, StreamUpdate,
    run_statements, run_statements_with_stream, sql_preview, statement_identity, summary_label,
};
use super::{statement_subject, uses_drop_down};
use relm4::gtk;
use relm4::gtk::prelude::*;
use tablepro_core::{ConnectOptions, DatabaseDriver};

type ReceivedRows = std::sync::Arc<std::sync::Mutex<Vec<(u64, Vec<tablepro_core::Value>)>>>;
type ReceivedPages = std::sync::Arc<std::sync::Mutex<Vec<(u64, Vec<Vec<tablepro_core::Value>>)>>>;

#[test]
fn a_statement_is_named_by_its_verb_and_the_table_it_touches() {
    let name = |sql: &str| statement_subject(sql);
    assert_eq!(
        name("select id, name from public.users where id = 1"),
        Some("SELECT public.users".into())
    );
    assert_eq!(name("SELECT 1"), Some("SELECT".into()));
    assert_eq!(
        name("insert into \"orders\" (a) values (1)"),
        Some("INSERT orders".into())
    );
    assert_eq!(name("UPDATE items SET a = 1"), Some("UPDATE items".into()));
    assert_eq!(name("DELETE FROM `logs`;"), Some("DELETE logs".into()));
    assert_eq!(name("create table if not exists t (id int)"), Some("CREATE t".into()));
    assert_eq!(name("DROP TABLE IF EXISTS old_t"), Some("DROP old_t".into()));
    assert_eq!(name("EXPLAIN select 1"), Some("EXPLAIN".into()));
    assert_eq!(name("   "), None);
}

#[test]
fn a_few_results_keep_their_buttons_and_many_collapse_into_a_drop_down() {
    assert!(!uses_drop_down(2));
    assert!(!uses_drop_down(5));
    assert!(uses_drop_down(6));
    assert!(uses_drop_down(40));
}

async fn sqlite_connection() -> std::sync::Arc<dyn tablepro_core::Connection> {
    let driver = drivers_sqlite::SqliteDriver;
    let connection = driver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .expect("in-memory sqlite connection");
    std::sync::Arc::from(connection)
}

async fn guarded_sqlite_file(
    service: &crate::services::database_service::DatabaseService,
    path: &std::path::Path,
) -> std::sync::Arc<dyn tablepro_core::Connection> {
    use crate::services::database_service::{ConnectionMetadata, ReconnectParams};
    let driver: std::sync::Arc<dyn DatabaseDriver> = std::sync::Arc::new(drivers_sqlite::SqliteDriver);
    let options = ConnectOptions {
        database: path.to_string_lossy().into_owned(),
        ..Default::default()
    };
    let id = uuid::Uuid::new_v4();
    let connection = driver.connect(options.clone()).await.expect("sqlite file connection");
    let metadata = ConnectionMetadata {
        id,
        name: "script".into(),
        driver_id: "sqlite".into(),
        environment: tablepro_core::Environment::Local,
        read_only: false,
        server_version: None,
        query_timeout_secs: None,
    };
    let reconnect = ReconnectParams {
        driver,
        opts: options,
        ssh: None,
        environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
    };
    assert!(service.activate(id, metadata, connection, None, false, reconnect));
    service.get(id).expect("guarded handle")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_script_rollback_cannot_silently_commit_the_statements_before_it() {
    let directory = tempfile::tempdir().unwrap();
    let service = crate::services::database_service::DatabaseService::new_isolated();
    let conn = guarded_sqlite_file(&service, &directory.path().join("script.db")).await;
    let control = crate::services::operation_control::bounded(0);
    conn.execute_controlled("CREATE TABLE t (id int)", &control)
        .await
        .unwrap();

    let result = run_statements(
        StatementTarget::Pool(conn.clone()),
        vec!["BEGIN".into(), "INSERT INTO t VALUES (1)".into(), "ROLLBACK".into()],
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::StopScript,
        |_| {},
    )
    .await;

    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    let StatementOutcomeKind::Error(message) = &outcomes[0].kind else {
        panic!("BEGIN must be refused: {:?}", outcomes[0].kind)
    };
    assert!(message.contains("transaction"), "{message}");
    assert!(matches!(outcomes[1].kind, StatementOutcomeKind::NotRun));
    let rows = conn.query_controlled("SELECT count(*) FROM t", &control).await.unwrap();
    assert_eq!(rows.rows, vec![vec![tablepro_core::Value::Int(0)]]);
}

struct SlowApproval {
    asked: std::sync::atomic::AtomicUsize,
}

#[async_trait::async_trait]
impl tablepro_policy::ApprovalSink for SlowApproval {
    async fn request(&self, _request: tablepro_policy::ApprovalRequest) -> tablepro_policy::ApprovalOutcome {
        self.asked.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        tablepro_policy::ApprovalOutcome::AllowOnce
    }
}

struct QuietAudit;

#[async_trait::async_trait]
impl tablepro_policy::AuditSink for QuietAudit {
    async fn record(&self, _event: tablepro_policy::AuditEvent) -> Result<(), tablepro_policy::AuditError> {
        Ok(())
    }
}

#[tokio::test]
async fn the_elapsed_time_of_a_statement_excludes_the_wait_for_approval() {
    let slow = std::sync::Arc::new(SlowApproval {
        asked: Default::default(),
    });
    let approval = std::sync::Arc::new(crate::services::approval_router::ApprovalRouter::new(
        slow.clone(),
        slow.clone(),
    ));
    let guard = tablepro_policy::PolicyGuard::new(
        sqlite_connection().await,
        tablepro_policy::GuardContext {
            connection_id: uuid::Uuid::new_v4(),
            connection_name: "production".into(),
            driver_id: "sqlite".into(),
            environment: tablepro_core::Environment::Prod,
            read_only: false,
            principal: tablepro_policy::Principal::human_gui(),
            policy: std::sync::Arc::new(tablepro_policy::PolicyConfig::default()),
            approval,
            audit: std::sync::Arc::new(QuietAudit),
            audit_state: std::sync::Arc::new(tablepro_policy::AuditState::new()),
        },
    );
    let control = crate::services::operation_control::bounded(0);
    let result = run_statements(
        StatementTarget::Pool(std::sync::Arc::new(guard)),
        vec!["CREATE TABLE t (id int)".into()],
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::StopScript,
        |_| {},
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    assert!(
        matches!(outcomes[0].kind, StatementOutcomeKind::Rows(_)),
        "{:?}",
        outcomes[0].kind
    );
    assert_eq!(
        slow.asked.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "the statement must ask for approval"
    );
    assert!(outcomes[0].elapsed_ms < 200, "{} ms", outcomes[0].elapsed_ms);
}

#[tokio::test]
async fn stop_script_policy_skips_statements_after_the_first_error() {
    let conn = sqlite_connection().await;
    let statements = vec!["CREATE TABLE t (id int)".into(), "not sql".into(), "SELECT 1".into()];
    let control = crate::services::operation_control::bounded(0);
    let result = run_statements(
        StatementTarget::Pool(conn),
        statements,
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::StopScript,
        |_| {},
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    assert!(matches!(outcomes[0].kind, StatementOutcomeKind::Rows(_)));
    assert!(matches!(outcomes[1].kind, StatementOutcomeKind::Error(_)));
    assert!(matches!(outcomes[2].kind, StatementOutcomeKind::NotRun));
}

#[tokio::test]
async fn continue_next_batch_policy_recovers_after_more_than_one_error() {
    let conn = sqlite_connection().await;
    let statements = vec![
        "CREATE TABLE t (id int)".into(),
        "not sql".into(),
        "also not sql".into(),
        "SELECT 1".into(),
    ];
    let control = crate::services::operation_control::bounded(0);
    let result = run_statements(
        StatementTarget::Pool(conn),
        statements,
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::ContinueNextBatch,
        |_| {},
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    assert!(!outcomes.iter().any(|o| matches!(o.kind, StatementOutcomeKind::NotRun)));
    assert!(matches!(outcomes[1].kind, StatementOutcomeKind::Error(_)));
    assert!(matches!(outcomes[2].kind, StatementOutcomeKind::Error(_)));
    assert!(matches!(outcomes[3].kind, StatementOutcomeKind::Rows(_)));
}

#[tokio::test]
async fn continue_next_batch_policy_also_recovers_from_a_parameter_bind_error() {
    let conn = sqlite_connection().await;
    let statements = vec!["SELECT :missing".into(), "SELECT 1".into()];
    let control = crate::services::operation_control::bounded(0);
    let result = run_statements(
        StatementTarget::Pool(conn),
        statements,
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::ContinueNextBatch,
        |_| {},
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    assert!(matches!(outcomes[0].kind, StatementOutcomeKind::Error(_)));
    assert!(
        matches!(outcomes[1].kind, StatementOutcomeKind::Rows(_)),
        "a bind error must not stop later batches under ContinueNextBatch"
    );
}

#[tokio::test]
async fn continue_next_batch_policy_still_runs_statements_after_an_error() {
    let conn = sqlite_connection().await;
    let statements = vec!["CREATE TABLE t (id int)".into(), "not sql".into(), "SELECT 1".into()];
    let control = crate::services::operation_control::bounded(0);
    let result = run_statements(
        StatementTarget::Pool(conn),
        statements,
        "sqlite",
        &Default::default(),
        &control,
        BatchErrorPolicy::ContinueNextBatch,
        |_| {},
    )
    .await;
    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("expected the run to complete")
    };
    assert!(matches!(outcomes[0].kind, StatementOutcomeKind::Rows(_)));
    assert!(matches!(outcomes[1].kind, StatementOutcomeKind::Error(_)));
    assert!(
        matches!(outcomes[2].kind, StatementOutcomeKind::Rows(_)),
        "a later batch must still run after an earlier batch's error under ContinueNextBatch"
    );
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_failed_statement_offers_a_copy_button() {
    use relm4::gtk::prelude::*;
    relm4::adw::init().unwrap();
    let page = super::error_page(0, "syntax error at position 8");
    let actions = page.child().unwrap();
    let button = actions.first_child().unwrap().downcast::<relm4::gtk::Button>().unwrap();
    assert_eq!(button.label().as_deref(), Some("Copy error"));
    let audit = actions.last_child().unwrap().downcast::<relm4::gtk::Button>().unwrap();
    assert_eq!(audit.label().as_deref(), Some("View in Audit Log"));
    assert_eq!(audit.action_name().as_deref(), Some("win.show-audit"));
    assert_eq!(page.description().as_deref(), Some("syntax error at position 8"));
}

#[test]
fn a_pinned_result_is_named_by_its_statement_without_a_run_number() {
    let outcome = super::StatementOutcome {
        identity: StatementIdentity::default(),
        sql_preview: "select * from public.users".into(),
        elapsed_ms: 3,
        kind: StatementOutcomeKind::Rows(Vec::new()),
        pinned: true,
    };
    assert_eq!(super::outcome_tab_label(&outcome), "📌 SELECT public.users (0)");
}

#[test]
fn a_fresh_result_keeps_its_script_number_after_pinned_results_precede_it() {
    let outcome = super::StatementOutcome {
        identity: StatementIdentity {
            statement_index: 1,
            digest: [0; 32],
        },
        sql_preview: "select * from missing_table".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Error("missing table".into()),
        pinned: false,
    };
    assert_eq!(super::outcome_tab_label(&outcome), "2 · SELECT missing_table (error)");
}

#[derive(Default)]
struct CursorCounters {
    opened: std::sync::atomic::AtomicUsize,
    fetched: std::sync::atomic::AtomicUsize,
    closed: std::sync::atomic::AtomicUsize,
    rolled_back: std::sync::atomic::AtomicUsize,
    transaction_open: std::sync::atomic::AtomicBool,
    cursor_open: std::sync::atomic::AtomicBool,
    lifecycle: std::sync::Mutex<Vec<&'static str>>,
}

struct CursorSession {
    pages: std::collections::VecDeque<Result<tablepro_core::QueryCursorPage, tablepro_core::DriverError>>,
    counters: std::sync::Arc<CursorCounters>,
    transaction_open: bool,
    cursor_open: bool,
}

#[async_trait::async_trait]
impl tablepro_core::Session for CursorSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _params: &[tablepro_core::Value],
        _control: &tablepro_core::OperationControl,
    ) -> Result<tablepro_core::QueryResult, tablepro_core::DriverError> {
        if sql.starts_with("BEGIN READ ONLY") {
            self.counters.lifecycle.lock().unwrap().push("begin");
            self.transaction_open = true;
            self.counters
                .transaction_open
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
        if sql == "ROLLBACK" {
            self.counters.lifecycle.lock().unwrap().push("rollback");
            self.transaction_open = false;
            self.cursor_open = false;
            self.counters
                .transaction_open
                .store(false, std::sync::atomic::Ordering::SeqCst);
            self.counters
                .cursor_open
                .store(false, std::sync::atomic::Ordering::SeqCst);
            self.counters
                .rolled_back
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        Ok(tablepro_core::QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    async fn open_query_cursor_controlled(
        &mut self,
        _sql: &str,
        _params: &[tablepro_core::Value],
        _control: &tablepro_core::OperationControl,
    ) -> Result<tablepro_core::QueryCursorId, tablepro_core::DriverError> {
        self.counters.lifecycle.lock().unwrap().push("open_cursor");
        self.cursor_open = true;
        self.counters
            .cursor_open
            .store(true, std::sync::atomic::Ordering::SeqCst);
        self.counters.opened.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(tablepro_core::QueryCursorId::new())
    }

    async fn fetch_query_cursor_page_controlled(
        &mut self,
        _cursor_id: tablepro_core::QueryCursorId,
        _control: &tablepro_core::OperationControl,
    ) -> Result<tablepro_core::QueryCursorPage, tablepro_core::DriverError> {
        self.counters.fetched.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        match self.pages.pop_front() {
            Some(Ok(page)) => Ok(page),
            Some(Err(error)) => Err(error),
            None => Err(tablepro_core::DriverError::Internal("no scripted cursor page".into())),
        }
    }

    async fn close_query_cursor_controlled(
        &mut self,
        _cursor_id: tablepro_core::QueryCursorId,
        _control: &tablepro_core::OperationControl,
    ) -> Result<(), tablepro_core::DriverError> {
        self.counters.lifecycle.lock().unwrap().push("close_cursor");
        self.cursor_open = false;
        self.counters
            .cursor_open
            .store(false, std::sync::atomic::Ordering::SeqCst);
        self.counters.closed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(())
    }

    fn is_usable(&self) -> bool {
        true
    }

    fn transaction_open(&self) -> bool {
        self.transaction_open
    }

    async fn close(self: Box<Self>) -> Result<(), tablepro_core::DriverError> {
        Ok(())
    }
}

fn cursor_page(values: &[i64], has_next_page: bool) -> tablepro_core::QueryCursorPage {
    use tablepro_core::{ColumnInfo, QueryResult, Value};
    tablepro_core::QueryCursorPage {
        result: QueryResult {
            columns: vec![ColumnInfo {
                name: "id".into(),
                data_type: "BIGINT".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: values.iter().map(|value| vec![Value::Int(*value)]).collect(),
            truncated: false,
        },
        has_next_page,
    }
}

fn cursor_page_with_values(values: Vec<tablepro_core::Value>, has_next_page: bool) -> tablepro_core::QueryCursorPage {
    let mut page = cursor_page(&[], has_next_page);
    let template = page.result.columns[0].clone();
    page.result.columns = values
        .iter()
        .enumerate()
        .map(|(index, _)| tablepro_core::ColumnInfo {
            name: format!("value_{index}"),
            data_type: "test value".into(),
            ..template.clone()
        })
        .collect();
    page.result.rows.push(values);
    page
}

fn cursor_target(
    pages: Vec<Result<tablepro_core::QueryCursorPage, tablepro_core::DriverError>>,
    counters: std::sync::Arc<CursorCounters>,
) -> StatementTarget {
    let session = CursorSession {
        pages: pages.into(),
        counters,
        transaction_open: false,
        cursor_open: false,
    };
    StatementTarget::Session {
        id: uuid::Uuid::new_v4(),
        shared: std::sync::Arc::new(tokio::sync::Mutex::new(Some(Box::new(session)))),
    }
}

fn streamed_update(
    counters: std::sync::Arc<CursorCounters>,
    received: ReceivedRows,
) -> impl FnMut(StreamUpdate) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>> {
    move |update| {
        let counters = counters.clone();
        let received = received.clone();
        Box::pin(async move {
            match update {
                StreamUpdate::Started { .. } => true,
                StreamUpdate::Page { sequence, page } => {
                    let fetched = counters.fetched.load(std::sync::atomic::Ordering::SeqCst);
                    if fetched != sequence as usize + 1 {
                        return false;
                    }
                    let rows = page.rows.iter().filter_map(|row| row.first().cloned()).collect();
                    received.lock().unwrap().push((sequence, rows));
                    true
                }
            }
        })
    }
}

fn record_streamed_pages(
    received: ReceivedPages,
) -> impl FnMut(StreamUpdate) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>> {
    move |update| {
        let received = received.clone();
        Box::pin(async move {
            match update {
                StreamUpdate::Started { .. } => true,
                StreamUpdate::Page { sequence, page } => {
                    received.lock().unwrap().push((sequence, page.rows.clone()));
                    true
                }
            }
        })
    }
}

fn reject_stream_page() -> impl FnMut(StreamUpdate) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>>
{
    move |update| Box::pin(async move { matches!(update, StreamUpdate::Started { .. }) })
}

fn query_export_runner(runtime: std::sync::Arc<tokio::runtime::Runtime>) -> crate::services::export_pages::PageRunner {
    std::sync::Arc::new(move |future| runtime.block_on(future))
}

fn query_export_factory(
    target: StatementTarget,
    runtime: std::sync::Arc<tokio::runtime::Runtime>,
) -> crate::ui::export_dialog::PageFetcherFactory {
    super::super::session_mode::query_cursor_export_factory_for_target(
        target,
        "SELECT id FROM items WHERE id > $1".into(),
        vec![tablepro_core::Value::Int(0)],
        30,
        query_export_runner(runtime),
    )
}

fn stream_export_origin() -> (
    std::sync::Arc<tokio::runtime::Runtime>,
    std::sync::Arc<crate::services::database_service::DatabaseService>,
    crate::services::catalog::CatalogOrigin,
) {
    let runtime = std::sync::Arc::new(
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap(),
    );
    let database = std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated());
    let driver: std::sync::Arc<dyn tablepro_core::DatabaseDriver> = std::sync::Arc::new(drivers_sqlite::SqliteDriver);
    let id = uuid::Uuid::new_v4();
    let options = tablepro_core::ConnectOptions {
        database: ":memory:".into(),
        ..Default::default()
    };
    let connection = runtime.block_on(driver.connect(options.clone())).unwrap();
    let activated = runtime.block_on(async {
        database.activate(
            id,
            crate::services::database_service::ConnectionMetadata {
                id,
                name: "stream export test".into(),
                driver_id: "sqlite".into(),
                environment: tablepro_core::Environment::Local,
                read_only: false,
                server_version: None,
                query_timeout_secs: None,
            },
            connection,
            None,
            false,
            crate::services::database_service::ReconnectParams {
                driver,
                opts: options,
                ssh: None,
                environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
            },
        )
    });
    assert!(activated);
    let origin = crate::services::catalog::CatalogOrigin::capture(Some(id), &database).unwrap();
    (runtime, database, origin)
}

fn stream_export_button(widget: &gtk::Widget) -> Option<gtk::Button> {
    let mut pending = std::collections::VecDeque::from([widget.clone()]);
    while let Some(current) = pending.pop_front() {
        if let Ok(button) = current.clone().downcast::<gtk::Button>()
            && button.label().as_deref() == Some("Export all rows…")
        {
            return Some(button);
        }
        let mut child = current.first_child();
        while let Some(node) = child {
            child = node.next_sibling();
            pending.push_back(node);
        }
    }
    None
}

fn streamed_result_notebook(
    pages: Vec<std::sync::Arc<tablepro_core::QueryResult>>,
    first_page: u64,
    total_pages: u64,
    total_rows: usize,
    terminal: StreamTerminal,
) -> gtk::Notebook {
    let page_indices = (first_page..first_page.saturating_add(pages.len() as u64)).collect();
    let streamed = StreamedResult {
        pages,
        page_indices,
        total_pages,
        total_rows,
        terminal,
        export: None,
    };
    let outcome = super::StatementOutcome {
        identity: StatementIdentity::default(),
        sql_preview: "SELECT id FROM items".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Streamed(Box::new(streamed.clone())),
        pinned: false,
    };
    let (grid_sender, _) = relm4::channel::<crate::ui::grid::GridMsg>();
    let widget = super::build_streamed_result_widget(
        &outcome,
        &streamed,
        &grid_sender,
        None,
        std::sync::Arc::new(crate::services::database_service::DatabaseService::new_isolated()),
        Default::default(),
    );
    widget.last_child().unwrap().downcast().unwrap()
}

fn streamed_page_tab_label(notebook: &gtk::Notebook, index: u32) -> String {
    let page = notebook.nth_page(Some(index)).unwrap();
    notebook.tab_label_text(&page).unwrap().to_string()
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn streamed_result_widgets_keep_pages_visible_during_loading_and_terminal_states() {
    relm4::adw::init().unwrap();
    let loading = streamed_result_notebook(
        vec![
            std::sync::Arc::new(cursor_page(&[1, 2], true).result),
            std::sync::Arc::new(cursor_page(&[3], false).result),
        ],
        0,
        2,
        3,
        StreamTerminal::Loading,
    );
    assert_eq!((loading.shows_tabs(), loading.n_pages()), (false, 2));
    assert_eq!(loading.current_page(), Some(1));
    assert_eq!(streamed_page_tab_label(&loading, 0), "Rows 1-2");
    assert_eq!(streamed_page_tab_label(&loading, 1), "Rows 3-3");

    let empty = streamed_result_notebook(
        vec![std::sync::Arc::new(cursor_page(&[], false).result)],
        0,
        1,
        0,
        StreamTerminal::Complete,
    );
    assert_eq!(empty.n_pages(), 1);
    assert_eq!(streamed_page_tab_label(&empty, 0), "Rows 0");

    let failed = streamed_result_notebook(
        vec![std::sync::Arc::new(cursor_page(&[4], true).result)],
        0,
        1,
        1,
        StreamTerminal::Failed("later page failed".into()),
    );
    assert_eq!(failed.n_pages(), 2);
    assert_eq!(failed.current_page(), Some(1));
    assert_eq!(streamed_page_tab_label(&failed, 0), "Rows 1-1");
    assert_eq!(streamed_page_tab_label(&failed, 1), "Status");
    let status = failed
        .nth_page(Some(1))
        .unwrap()
        .downcast::<relm4::adw::StatusPage>()
        .unwrap();
    assert_eq!(status.description().as_deref(), Some("later page failed"));

    let cancelled = streamed_result_notebook(
        vec![std::sync::Arc::new(cursor_page(&[5], true).result)],
        0,
        1,
        1,
        StreamTerminal::Cancelled,
    );
    assert_eq!(cancelled.n_pages(), 2);
    assert_eq!(cancelled.current_page(), Some(1));
    assert_eq!(streamed_page_tab_label(&cancelled, 0), "Rows 1-1");
    let status = cancelled
        .nth_page(Some(1))
        .unwrap()
        .downcast::<relm4::adw::StatusPage>()
        .unwrap();
    assert_eq!(status.title(), "Query cancelled");
}

#[tokio::test]
async fn postgres_editor_streams_pages_in_order_with_one_fetch_in_flight() {
    let counters = std::sync::Arc::new(CursorCounters::default());
    let received = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let result = run_statements_with_stream(
        StatementRun {
            target: cursor_target(
                vec![Ok(cursor_page(&[1, 2], true)), Ok(cursor_page(&[3], false))],
                counters.clone(),
            ),
            statements: vec!["SELECT id FROM items".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        streamed_update(counters.clone(), received.clone()),
    )
    .await;

    assert!(matches!(result, ScriptRunResult::Streamed(StreamTerminal::Complete)));
    assert_eq!(
        *received.lock().unwrap(),
        [
            (0, vec![tablepro_core::Value::Int(1), tablepro_core::Value::Int(2)]),
            (1, vec![tablepro_core::Value::Int(3)]),
        ]
    );
    assert_eq!(counters.opened.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.fetched.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(counters.closed.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn streamed_cursor_pages_preserve_native_values_across_page_boundaries() {
    use tablepro_core::Value;

    let first = vec![
        Value::Null,
        Value::Bool(true),
        Value::Bytes(vec![0, 255]),
        Value::Decimal(rust_decimal::Decimal::new(12345, 2)),
        Value::Json(serde_json::json!({"kind": "native"})),
        Value::Undecodable("custom_type".into()),
    ];
    let second = vec![
        Value::Int(9),
        Value::Float(1.25),
        Value::Text("text".into()),
        Value::JsonText("{\"kind\":\"text\"}".into()),
        Value::Uuid(uuid::Uuid::nil()),
        Value::Null,
    ];
    let received: ReceivedPages = Default::default();
    let result = run_statements_with_stream(
        StatementRun {
            target: cursor_target(
                vec![
                    Ok(cursor_page_with_values(first.clone(), true)),
                    Ok(cursor_page_with_values(second.clone(), false)),
                ],
                std::sync::Arc::new(CursorCounters::default()),
            ),
            statements: vec!["SELECT typed_values".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        record_streamed_pages(received.clone()),
    )
    .await;

    assert!(matches!(result, ScriptRunResult::Streamed(StreamTerminal::Complete)));
    assert_eq!(*received.lock().unwrap(), [(0, vec![first]), (1, vec![second])]);
}

#[tokio::test]
async fn a_late_cursor_error_keeps_prior_pages_and_rolls_back_the_snapshot() {
    let counters = std::sync::Arc::new(CursorCounters::default());
    let received = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let result = run_statements_with_stream(
        StatementRun {
            target: cursor_target(
                vec![
                    Ok(cursor_page(&[1], true)),
                    Err(tablepro_core::DriverError::Query {
                        message: "later page failed".into(),
                        sqlstate: Some("XX000".into()),
                        position: None,
                    }),
                ],
                counters.clone(),
            ),
            statements: vec!["SELECT id FROM items".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        streamed_update(counters.clone(), received.clone()),
    )
    .await;

    assert!(matches!(result, ScriptRunResult::Streamed(StreamTerminal::Failed(_))));
    assert_eq!(received.lock().unwrap().len(), 1);
    assert_eq!(counters.fetched.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cancelling_page_delivery_closes_the_cursor_and_rolls_back() {
    let counters = std::sync::Arc::new(CursorCounters::default());
    let result = run_statements_with_stream(
        StatementRun {
            target: cursor_target(vec![Ok(cursor_page(&[1], true))], counters.clone()),
            statements: vec!["SELECT id FROM items".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        reject_stream_page(),
    )
    .await;

    assert!(matches!(result, ScriptRunResult::Streamed(StreamTerminal::Cancelled)));
    assert_eq!(counters.fetched.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.closed.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(
        *counters.lifecycle.lock().unwrap(),
        ["begin", "open_cursor", "close_cursor", "rollback"]
    );
}

#[tokio::test]
async fn cancelling_during_fetch_rolls_back_and_keeps_the_session_usable() {
    let counters = std::sync::Arc::new(CursorCounters::default());
    let target = cursor_target(vec![Err(tablepro_core::DriverError::Cancelled)], counters.clone());
    let result = run_statements_with_stream(
        StatementRun {
            target: target.clone(),
            statements: vec!["SELECT id FROM items".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &crate::services::operation_control::bounded(30),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        |_update| std::future::ready(true),
    )
    .await;

    assert!(matches!(result, ScriptRunResult::Streamed(StreamTerminal::Cancelled)));
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert!(!counters.transaction_open.load(std::sync::atomic::Ordering::SeqCst));
    assert!(!counters.cursor_open.load(std::sync::atomic::Ordering::SeqCst));
    assert!(matches!(target.session_state().await, Some((_, false, true))));
}

#[test]
fn guarded_query_export_reads_every_page_and_releases_its_cursor() {
    let runtime = std::sync::Arc::new(
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap(),
    );
    let counters = std::sync::Arc::new(CursorCounters::default());
    let target = cursor_target(
        vec![Ok(cursor_page(&[1, 2], true)), Ok(cursor_page(&[3], false))],
        counters.clone(),
    );
    let mut pages = query_export_factory(target, runtime)(tokio_util::sync::CancellationToken::new());
    let mut rows = Vec::new();
    while let Some(page) = pages.next_page().unwrap() {
        rows.extend(page.into_iter().map(|row| row[0].clone()));
    }
    pages.finish().unwrap();

    assert_eq!(rows, [1, 2, 3].map(tablepro_core::Value::Int));
    assert_eq!(counters.opened.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.fetched.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(counters.closed.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[test]
fn guarded_query_export_failure_rolls_back_and_keeps_the_database_error() {
    let runtime = std::sync::Arc::new(
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap(),
    );
    let counters = std::sync::Arc::new(CursorCounters::default());
    let target = cursor_target(
        vec![
            Ok(cursor_page(&[1], true)),
            Err(tablepro_core::DriverError::Query {
                message: "later page failed".into(),
                sqlstate: Some("XX000".into()),
                position: None,
            }),
        ],
        counters.clone(),
    );
    let mut pages = query_export_factory(target, runtime)(tokio_util::sync::CancellationToken::new());
    assert_eq!(pages.next_page().unwrap().unwrap().len(), 1);
    let error = pages.next_page().unwrap_err();
    pages.finish().unwrap();

    assert!(matches!(error, tablepro_core::export::ExportError::Source(_)));
    assert_eq!(counters.rolled_back.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(counters.closed.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn exporting_after_partial_view_uses_the_guarded_query_and_its_bind_values() {
    relm4::adw::init().unwrap();
    let (_runtime, database, origin) = stream_export_origin();
    let page = std::sync::Arc::new(cursor_page(&[1, 2], true).result);
    let request = crate::ui::export_dialog::StreamExportRequest {
        query: crate::ui::export_dialog::StreamExportQuery {
            origin: origin.clone(),
            driver_id: "sqlite".into(),
            sql: "SELECT id FROM items WHERE id > ?".into(),
            params: vec![tablepro_core::Value::Int(0)],
            timeout_secs: 30,
            suggested_name: "items".into(),
            session: None,
        },
        columns: page.columns.clone(),
    };
    let streamed = StreamedResult {
        pages: vec![page],
        page_indices: vec![2],
        total_pages: 4,
        total_rows: tablepro_core::MAX_QUERY_CURSOR_PAGE_ROWS * 3 + 2,
        terminal: StreamTerminal::Loading,
        export: Some(request.clone()),
    };
    let outcome = super::StatementOutcome {
        identity: StatementIdentity {
            statement_index: 0,
            digest: [7; 32],
        },
        sql_preview: "SELECT id FROM items".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Streamed(Box::new(streamed.clone())),
        pinned: false,
    };
    let (grid_sender, receiver) = relm4::channel::<crate::ui::grid::GridMsg>();
    let widget = super::build_streamed_result_widget(
        &outcome,
        &streamed,
        &grid_sender,
        Some(origin.id),
        database,
        Default::default(),
    );

    let button = stream_export_button(&widget).unwrap();
    button.emit_clicked();
    let Some(crate::ui::grid::GridMsg::ExportStreamedResults(export)) = receiver.recv_sync() else {
        panic!("the export action must carry a full query export request");
    };

    assert_eq!(export.query.origin, origin);
    assert_eq!(export.query.sql, "SELECT id FROM items WHERE id > ?");
    assert_eq!(export.query.params, [tablepro_core::Value::Int(0)]);
    assert_eq!(export.query.suggested_name, "items");
    assert_eq!(export.columns[0].name, "id");
    assert_eq!(streamed.pages.len(), 1);
    assert!(streamed.total_rows > streamed.pages[0].rows.len());
}

#[test]
fn sql_preview_collapses_whitespace_and_truncates() {
    let preview = sql_preview("SELECT *\n  FROM   users\n  WHERE id = 1");
    assert_eq!(preview, "SELECT * FROM users WHERE id = 1");
}

#[test]
fn statement_identity_changes_when_position_or_sql_changes() {
    assert_ne!(statement_identity(0, "SELECT 1"), statement_identity(1, "SELECT 1"));
    assert_ne!(statement_identity(0, "SELECT 1"), statement_identity(0, "SELECT 2"));
    assert_eq!(statement_identity(0, "SELECT 1"), statement_identity(0, "SELECT 1"));
}

#[test]
fn sql_preview_appends_ellipsis_when_too_long() {
    let long = "SELECT col1, col2, col3, col4, col5, col6, col7, col8, col9 FROM users WHERE id = 1";
    let preview = sql_preview(long);
    assert!(preview.ends_with('…'));
    assert!(preview.chars().count() <= 61);
}

#[test]
fn summary_label_single_statement_done() {
    let s = summary_label(1, 1, 42, false);
    assert!(s.contains("42"));
    assert!(!s.contains("/"));
}

#[test]
fn summary_label_multi_statement_includes_counts() {
    let s = summary_label(3, 2, 100, true);
    assert!(s.contains("2/3"));
    assert!(s.contains("100"));
}

fn outcome_with(kind: StatementOutcomeKind, pinned: bool) -> super::StatementOutcome {
    super::StatementOutcome {
        identity: StatementIdentity::default(),
        sql_preview: "SELECT 1".into(),
        elapsed_ms: 0,
        kind,
        pinned,
    }
}

fn streamed_kind(terminal: StreamTerminal) -> StatementOutcomeKind {
    StatementOutcomeKind::Streamed(Box::new(StreamedResult {
        pages: Vec::new(),
        page_indices: Vec::new(),
        total_pages: 0,
        total_rows: 0,
        terminal,
        export: None,
    }))
}

#[test]
fn a_failed_or_timed_out_stream_is_the_result_shown_first() {
    for terminal in [
        StreamTerminal::Failed("division by zero".into()),
        StreamTerminal::TimedOut,
    ] {
        let outcomes = vec![
            outcome_with(StatementOutcomeKind::Rows(Vec::new()), true),
            outcome_with(streamed_kind(terminal), false),
        ];
        assert_eq!(super::first_failure(&outcomes), Some(1));
    }
    let complete = vec![
        outcome_with(StatementOutcomeKind::Rows(Vec::new()), true),
        outcome_with(streamed_kind(StreamTerminal::Complete), false),
    ];
    assert_eq!(super::first_failure(&complete), None);
}

#[test]
fn skipped_empty_stream_page_does_not_shift_retained_result_identity() {
    let mut cache = super::super::stream_pages::StreamPageCache::default();
    for (index, values, has_next_page) in [(0, &[1][..], true), (1, &[][..], true), (2, &[2][..], false)] {
        cache
            .append(index, std::sync::Arc::new(cursor_page(values, has_next_page).result))
            .unwrap();
    }
    let outcome = super::StatementOutcome {
        identity: StatementIdentity::default(),
        sql_preview: "SELECT id FROM items".into(),
        elapsed_ms: 0,
        kind: StatementOutcomeKind::Streamed(Box::new(cache.snapshot(StreamTerminal::Complete, None))),
        pinned: false,
    };

    let indexes = super::result_view_keys(&[outcome])
        .into_iter()
        .map(|key| key.result_set_index)
        .collect::<std::collections::HashSet<_>>();

    assert_eq!(indexes, std::collections::HashSet::from([0, 2]));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_select_that_calls_a_writing_function_runs_outside_a_read_only_cursor() {
    use testcontainers::ImageExt;
    use testcontainers::runners::AsyncRunner;
    use testcontainers_modules::postgres::Postgres;

    let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
    let connection: std::sync::Arc<dyn tablepro_core::Connection> = std::sync::Arc::from(
        drivers_postgres::PgDriver
            .connect(ConnectOptions {
                host: container.get_host().await.unwrap().to_string(),
                port: container.get_host_port_ipv4(5432).await.unwrap(),
                database: "postgres".into(),
                username: "postgres".into(),
                password: secrecy::SecretString::new("postgres".into()),
                ..Default::default()
            })
            .await
            .unwrap(),
    );
    let control = crate::services::operation_control::bounded(30);
    for sql in [
        "CREATE TABLE archived (id int)",
        "CREATE FUNCTION archive_rows() RETURNS int LANGUAGE sql AS 'INSERT INTO archived VALUES (1) RETURNING id'",
    ] {
        connection.execute_controlled(sql, &control).await.unwrap();
    }
    let streamed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let seen = streamed.clone();
    let result = run_statements_with_stream(
        StatementRun {
            target: StatementTarget::Pool(connection.clone()),
            statements: vec!["SELECT archive_rows()".into()],
            driver_id: "postgres",
            parameter_values: &Default::default(),
            control: &control,
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
            succeeded: |_: &str| {},
        },
        move |_| {
            seen.store(true, std::sync::atomic::Ordering::SeqCst);
            async { true }
        },
    )
    .await;

    let ScriptRunResult::Completed(outcomes) = result else {
        panic!("the statement runs without a cursor");
    };
    assert!(
        matches!(&outcomes[0].kind, StatementOutcomeKind::Rows(sets) if sets[0].rows == [[tablepro_core::Value::Int(1)]]),
        "{:?}",
        outcomes[0].kind
    );
    assert!(!streamed.load(std::sync::atomic::Ordering::SeqCst));
    let stored = connection
        .query_controlled("SELECT count(*) FROM archived", &control)
        .await
        .unwrap();
    assert_eq!(stored.rows, [[tablepro_core::Value::Int(1)]]);
}

#[path = "fetch_errors.rs"]
mod fetch_errors;
