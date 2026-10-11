use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use super::{StatementOutcome, StatementOutcomeKind};
use crate::ui::grid::{GridMsg, TabGridContext, build_column_view};
use tablepro_core::sql_syntax::script::BatchErrorPolicy;
use tablepro_core::{DriverError, OperationControl};

pub(crate) fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

pub(super) struct RunTotals {
    pub(super) elapsed_ms: u128,
    pub(super) statements: usize,
    pub(super) succeeded: usize,
    pub(super) first_error: Option<String>,
    pub(super) rows: i64,
}

impl RunTotals {
    pub(super) fn summary(&self) -> String {
        summary_label(
            self.statements,
            self.succeeded,
            self.elapsed_ms,
            self.first_error.is_some(),
        )
    }

    pub(super) fn history_rows(&self) -> Option<i64> {
        (self.rows > 0).then_some(self.rows)
    }

    pub(super) fn history_outcome(&self) -> tablepro_storage::query_history::Outcome {
        match &self.first_error {
            Some(message) => tablepro_storage::query_history::Outcome::Error(message.clone()),
            None => tablepro_storage::query_history::Outcome::Success,
        }
    }

    pub(super) fn of(outcomes: &[StatementOutcome]) -> Self {
        let rows_in = |outcome: &StatementOutcome| match &outcome.kind {
            StatementOutcomeKind::Rows(result_sets) => {
                Some(result_sets.iter().map(|result| result.rows.len() as i64).sum::<i64>())
            }
            _ => None,
        };
        Self {
            elapsed_ms: outcomes.iter().map(|outcome| outcome.elapsed_ms).sum(),
            statements: outcomes.len(),
            succeeded: outcomes
                .iter()
                .filter(|outcome| matches!(outcome.kind, StatementOutcomeKind::Rows(_)))
                .count(),
            first_error: outcomes.iter().find_map(|outcome| match &outcome.kind {
                StatementOutcomeKind::Error(message) => Some(message.clone()),
                _ => None,
            }),
            rows: outcomes.iter().filter_map(rows_in).sum(),
        }
    }
}

pub(crate) enum ScriptRunResult {
    Completed(Vec<StatementOutcome>),
    Cancelled,
    TimedOut,
}

pub(crate) async fn run_statements(
    target: super::session_mode::StatementTarget,
    statements: Vec<String>,
    driver_id: &str,
    parameter_values: &std::collections::HashMap<String, tablepro_core::Value>,
    control: &OperationControl,
    error_policy: BatchErrorPolicy,
    succeeded: impl Fn(&str),
) -> ScriptRunResult {
    crate::services::approval_wait::track(run_tracked_statements(
        target,
        statements,
        driver_id,
        parameter_values,
        control,
        error_policy,
        succeeded,
    ))
    .await
}

async fn run_tracked_statements(
    target: super::session_mode::StatementTarget,
    statements: Vec<String>,
    driver_id: &str,
    parameter_values: &std::collections::HashMap<String, tablepro_core::Value>,
    control: &OperationControl,
    error_policy: BatchErrorPolicy,
    succeeded: impl Fn(&str),
) -> ScriptRunResult {
    if statements.is_empty() {
        return ScriptRunResult::Completed(Vec::new());
    }
    let stops_on_error = error_policy == BatchErrorPolicy::StopScript;
    let mut out = Vec::with_capacity(statements.len());
    let mut aborted = false;
    for sql in statements.into_iter() {
        let preview = sql_preview(&sql);
        if aborted {
            out.push(StatementOutcome {
                sql_preview: preview,
                elapsed_ms: 0,
                kind: StatementOutcomeKind::NotRun,
                pinned: false,
            });
            continue;
        }
        let started = std::time::Instant::now();
        let waited_before = crate::services::approval_wait::waited();
        let bound = match crate::services::query_parameters::bind_statement(&sql, driver_id, parameter_values) {
            Ok(bound) => bound,
            Err(reason) => {
                out.push(StatementOutcome {
                    sql_preview: preview,
                    elapsed_ms: 0,
                    kind: StatementOutcomeKind::Error(reason),
                    pinned: false,
                });
                aborted = stops_on_error;
                continue;
            }
        };
        let kind = match target.query(&bound.sql, &bound.values, control).await {
            Ok(qr) => {
                succeeded(&sql);
                StatementOutcomeKind::Rows(qr.result_sets.into_iter().map(std::sync::Arc::new).collect())
            }
            Err(DriverError::Cancelled) => return ScriptRunResult::Cancelled,
            Err(DriverError::TimedOut) => return ScriptRunResult::TimedOut,

            Err(e) => {
                aborted = stops_on_error;
                StatementOutcomeKind::Error(failure_message(&e, &sql, &bound.sql))
            }
        };
        out.push(StatementOutcome {
            sql_preview: preview,
            elapsed_ms: started
                .elapsed()
                .saturating_sub(crate::services::approval_wait::waited().saturating_sub(waited_before))
                .as_millis(),
            kind,
            pinned: false,
        });
    }
    ScriptRunResult::Completed(out)
}

fn failure_message(error: &DriverError, written: &str, sent: &str) -> String {
    let position = match error {
        DriverError::Query { position, .. } if sent == written => *position,
        _ => None,
    };
    let message = crate::ui::error_text::driver_message(error);
    super::error_location::located_message(&message, sent, position)
}

fn sql_preview(sql: &str) -> String {
    let single_line: String = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() > 60 {
        let prefix: String = single_line.chars().take(60).collect();
        format!("{prefix}…")
    } else {
        single_line
    }
}

pub(crate) fn summary_label(n_total: usize, n_ok: usize, total_ms: u128, has_error: bool) -> String {
    if n_total == 1 {
        let ms = total_ms.to_string();
        if has_error {
            crate::tr!("error in {ms} ms").replace("{ms}", &ms)
        } else {
            crate::tr!("done in {ms} ms").replace("{ms}", &ms)
        }
    } else {
        let ok_s = n_ok.to_string();
        let total_s = n_total.to_string();
        let ms = total_ms.to_string();
        let base = crate::tr!("{ok}/{total} statements · {ms} ms")
            .replace("{ok}", &ok_s)
            .replace("{total}", &total_s)
            .replace("{ms}", &ms);
        if has_error {
            format!("{base} · {}", crate::tr!("error"))
        } else {
            base
        }
    }
}

fn build_outcome_widget(
    o: &StatementOutcome,
    idx: usize,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
) -> gtk::Widget {
    match &o.kind {
        StatementOutcomeKind::Rows(result_sets) if result_sets.len() > 1 => {
            let stack = adw::ViewStack::new();
            let labels = result_sets
                .iter()
                .enumerate()
                .map(|(index, result)| {
                    crate::tr!("Result set {n} ({rows})")
                        .replace("{n}", &(index + 1).to_string())
                        .replace("{rows}", &result.rows.len().to_string())
                })
                .collect::<Vec<_>>();
            for (index, result) in result_sets.iter().enumerate() {
                let widget = build_result_set_widget(result, grid_sender, connection_id, database.clone());
                stack.add_titled(&widget, Some(&format!("set{index}")), &labels[index]);
            }
            let dropdown = gtk::DropDown::from_strings(&labels.iter().map(String::as_str).collect::<Vec<_>>());
            dropdown.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Result set"))]);
            dropdown.connect_selected_notify({
                let stack = stack.downgrade();
                move |dropdown| {
                    if let Some(stack) = stack.upgrade() {
                        stack.set_visible_child_name(&format!("set{}", dropdown.selected()));
                    }
                }
            });
            let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
            holder.append(&dropdown);
            holder.append(&stack);
            holder.upcast()
        }
        StatementOutcomeKind::Rows(result_sets) if let Some(result) = result_sets.first() => {
            build_result_set_widget(result, grid_sender, connection_id, database)
        }
        StatementOutcomeKind::Rows(_) => {
            let ms = o.elapsed_ms.to_string();
            adw::StatusPage::builder()
                .title(crate::tr!("Statement {n} executed").replace("{n}", &(idx + 1).to_string()))
                .description(crate::tr!("No rows returned · {ms} ms").replace("{ms}", &ms))
                .icon_name("emblem-default-symbolic")
                .vexpand(true)
                .build()
                .upcast()
        }
        StatementOutcomeKind::Error(msg) => error_page(idx, msg).upcast(),
        StatementOutcomeKind::NotRun => adw::StatusPage::builder()
            .title(crate::tr!("Statement {n} not run").replace("{n}", &(idx + 1).to_string()))
            .description(crate::tr!("Skipped because an earlier statement failed."))
            .icon_name("media-playback-stop-symbolic")
            .vexpand(true)
            .build()
            .upcast(),
    }
}

fn error_page(idx: usize, message: &str) -> adw::StatusPage {
    let copy = gtk::Button::builder()
        .label(crate::tr!("Copy error"))
        .halign(gtk::Align::Center)
        .css_classes(["pill"])
        .build();
    let text = message.to_string();
    copy.connect_clicked(move |button| button.clipboard().set_text(&text));
    adw::StatusPage::builder()
        .title(crate::tr!("Statement {n} failed").replace("{n}", &(idx + 1).to_string()))
        .description(message)
        .icon_name("dialog-error-symbolic")
        .child(&copy)
        .vexpand(true)
        .build()
}

fn build_result_set_widget(
    result: &std::sync::Arc<tablepro_core::QueryResult>,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
) -> gtk::Widget {
    if result.columns.is_empty() {
        return adw::StatusPage::builder()
            .title(crate::tr!("No rows returned"))
            .icon_name("emblem-default-symbolic")
            .vexpand(true)
            .build()
            .upcast();
    }
    let (column_view, _selection) = build_column_view(
        result,
        &result.columns,
        "",
        None,
        Some(grid_sender.clone()),
        None,
        None,
        connection_id,
        TabGridContext {
            preview_result_values: true,
            ..Default::default()
        },
        None,
        database,
    );
    gtk::ScrolledWindow::builder()
        .child(&column_view)
        .hexpand(true)
        .vexpand(true)
        .build()
        .upcast()
}

fn clean_identifier(token: &str) -> String {
    token
        .trim_matches(|c: char| matches!(c, '(' | ')' | ';' | ',' | '"' | '`' | '[' | ']'))
        .to_string()
}

fn token_after(tokens: &[&str], keyword: &str) -> Option<String> {
    let position = tokens.iter().position(|token| token.eq_ignore_ascii_case(keyword))?;
    let name = clean_identifier(tokens.get(position + 1)?);
    (!name.is_empty()).then_some(name)
}

fn statement_subject(sql: &str) -> Option<String> {
    let tokens: Vec<&str> = sql.split_whitespace().collect();
    let verb = tokens.first()?.to_uppercase();
    let subject = match verb.as_str() {
        "SELECT" | "DELETE" => token_after(&tokens, "FROM"),
        "INSERT" | "REPLACE" => token_after(&tokens, "INTO"),
        "UPDATE" => tokens.get(1).map(|token| clean_identifier(token)),
        "CREATE" | "DROP" | "ALTER" | "TRUNCATE" => tokens
            .iter()
            .skip(1)
            .filter(|token| {
                !matches!(
                    token.to_uppercase().as_str(),
                    "IF" | "NOT" | "EXISTS" | "OR" | "REPLACE"
                )
            })
            .nth(1)
            .map(|token| clean_identifier(token)),
        _ => None,
    };
    Some(match subject.filter(|name| !name.is_empty()) {
        Some(name) => format!("{verb} {name}"),
        None => verb,
    })
}

fn outcome_tab_label(idx: usize, o: &StatementOutcome) -> String {
    if o.pinned {
        return pinned_tab_label(o);
    }
    let n = (idx + 1).to_string();
    let Some(statement) = statement_subject(&o.sql_preview) else {
        return match &o.kind {
            StatementOutcomeKind::Rows(sets) => crate::tr!("Result {n} ({rows})")
                .replace("{n}", &n)
                .replace("{rows}", &result_rows(sets).to_string()),
            StatementOutcomeKind::Error(_) => crate::tr!("Result {n} (error)").replace("{n}", &n),
            StatementOutcomeKind::NotRun => crate::tr!("Result {n} (skipped)").replace("{n}", &n),
        };
    };
    match &o.kind {
        StatementOutcomeKind::Rows(sets) => crate::tr!("{n} · {statement} ({rows})")
            .replace("{n}", &n)
            .replace("{statement}", &statement)
            .replace("{rows}", &result_rows(sets).to_string()),
        StatementOutcomeKind::Error(_) => crate::tr!("{n} · {statement} (error)")
            .replace("{n}", &n)
            .replace("{statement}", &statement),
        StatementOutcomeKind::NotRun => crate::tr!("{n} · {statement} (skipped)")
            .replace("{n}", &n)
            .replace("{statement}", &statement),
    }
}

fn pinned_tab_label(o: &StatementOutcome) -> String {
    let rows = match &o.kind {
        StatementOutcomeKind::Rows(sets) => result_rows(sets).to_string(),
        _ => String::new(),
    };
    let subject = statement_subject(&o.sql_preview).unwrap_or_else(|| crate::tr!("Result"));
    crate::tr!("📌 {statement} ({rows})")
        .replace("{statement}", &subject)
        .replace("{rows}", &rows)
}

fn result_rows(result_sets: &[std::sync::Arc<tablepro_core::QueryResult>]) -> usize {
    result_sets.iter().map(|result| result.rows.len()).sum()
}

const MAX_SWITCHER_BUTTONS: usize = 5;

fn uses_drop_down(count: usize) -> bool {
    count > MAX_SWITCHER_BUTTONS
}

fn build_result_switcher(stack: &adw::ViewStack, outcomes: &[StatementOutcome]) -> gtk::CenterBox {
    let holder = gtk::CenterBox::builder()
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    if uses_drop_down(outcomes.len()) {
        holder.set_center_widget(Some(&build_result_drop_down(stack, outcomes)));
    } else {
        let switcher = adw::ViewSwitcher::builder()
            .stack(stack)
            .policy(adw::ViewSwitcherPolicy::Wide)
            .build();
        holder.set_center_widget(Some(&switcher));
    }
    holder
}

fn build_result_drop_down(stack: &adw::ViewStack, outcomes: &[StatementOutcome]) -> gtk::DropDown {
    let labels: Vec<String> = outcomes
        .iter()
        .enumerate()
        .map(|(idx, outcome)| outcome_tab_label(idx, outcome))
        .collect();
    let label_refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let drop_down = gtk::DropDown::from_strings(&label_refs);
    drop_down.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Statement result"))]);
    let first_error = outcomes
        .iter()
        .position(|outcome| matches!(outcome.kind, StatementOutcomeKind::Error(_)))
        .unwrap_or(0);
    drop_down.set_selected(first_error as u32);
    drop_down.connect_selected_notify({
        let stack = stack.downgrade();
        move |drop_down| {
            if let Some(stack) = stack.upgrade() {
                stack.set_visible_child_name(&format!("r{}", drop_down.selected()));
            }
        }
    });
    drop_down
}

pub(crate) fn render_outcomes(
    holder: &gtk::Box,
    outcomes: &[StatementOutcome],
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
) {
    if outcomes.is_empty() {
        let placeholder = adw::StatusPage::builder()
            .title(crate::tr!("Empty query"))
            .description(crate::tr!("Type a SQL statement and press Run."))
            .icon_name("text-x-generic-symbolic")
            .vexpand(true)
            .build();
        holder.append(&placeholder);
        return;
    }
    if outcomes.len() == 1 {
        let widget = build_outcome_widget(&outcomes[0], 0, grid_sender, connection_id, database);
        holder.append(&widget);
        return;
    }
    let stack = adw::ViewStack::new();
    for (idx, o) in outcomes.iter().enumerate() {
        let widget = build_outcome_widget(o, idx, grid_sender, connection_id, database.clone());
        let icon = match &o.kind {
            StatementOutcomeKind::Rows(_) => "view-grid-symbolic",
            StatementOutcomeKind::Error(_) => "dialog-error-symbolic",
            StatementOutcomeKind::NotRun => "emblem-synchronizing-symbolic",
        };
        let page = stack.add_titled_with_icon(&widget, Some(&format!("r{idx}")), &outcome_tab_label(idx, o), icon);
        if !o.sql_preview.is_empty() {
            widget.set_tooltip_text(Some(&o.sql_preview));
            let _ = page;
        }
    }
    holder.append(&build_result_switcher(&stack, outcomes));
    holder.append(&stack);
    if let Some(err_idx) = outcomes
        .iter()
        .position(|o| matches!(o.kind, StatementOutcomeKind::Error(_)))
    {
        stack.set_visible_child_name(&format!("r{err_idx}"));
    }
}

#[cfg(test)]
mod tests {
    use super::super::session_mode::StatementTarget;
    use super::{BatchErrorPolicy, ScriptRunResult, StatementOutcomeKind, run_statements, sql_preview, summary_label};
    use super::{statement_subject, uses_drop_down};
    use tablepro_core::{ConnectOptions, DatabaseDriver};

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
        let button = page.child().unwrap().downcast::<relm4::gtk::Button>().unwrap();
        assert_eq!(button.label().as_deref(), Some("Copy error"));
        assert_eq!(page.description().as_deref(), Some("syntax error at position 8"));
    }

    #[test]
    fn a_pinned_result_is_named_by_its_statement_without_a_run_number() {
        let outcome = super::StatementOutcome {
            sql_preview: "select * from public.users".into(),
            elapsed_ms: 3,
            kind: StatementOutcomeKind::Rows(Vec::new()),
            pinned: true,
        };
        assert_eq!(super::outcome_tab_label(4, &outcome), "📌 SELECT public.users (0)");
    }

    #[test]
    fn sql_preview_collapses_whitespace_and_truncates() {
        let preview = sql_preview("SELECT *\n  FROM   users\n  WHERE id = 1");
        assert_eq!(preview, "SELECT * FROM users WHERE id = 1");
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
}
