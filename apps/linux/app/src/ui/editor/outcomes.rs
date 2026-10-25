use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use super::stream_pages::{StreamTerminal, StreamedResult};
use super::{StatementIdentity, StatementOutcome, StatementOutcomeKind};
use crate::ui::grid::local_filter::{LocalResultSettingsStore, ResultViewKey};
use crate::ui::grid::{GridMsg, TabGridContext, build_column_view};
use sha2::{Digest, Sha256};
use std::future::Future;
use tablepro_core::sql_syntax::script::{BatchErrorPolicy, LexicalSettings};
use tablepro_core::{DriverError, OperationControl, QueryResult};

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
            StatementOutcomeKind::Streamed(result) => Some(result.total_rows as i64),
            StatementOutcomeKind::Error(_) | StatementOutcomeKind::NotRun => None,
        };
        Self {
            elapsed_ms: outcomes.iter().map(|outcome| outcome.elapsed_ms).sum(),
            statements: outcomes.len(),
            succeeded: outcomes
                .iter()
                .filter(|outcome| {
                    matches!(outcome.kind, StatementOutcomeKind::Rows(_))
                        || matches!(outcome.kind, StatementOutcomeKind::Streamed(_))
                })
                .count(),
            first_error: outcomes.iter().find_map(|outcome| match &outcome.kind {
                StatementOutcomeKind::Error(message) => Some(message.to_string()),
                StatementOutcomeKind::Streamed(result) => match &result.terminal {
                    StreamTerminal::Failed(message) => Some(message.to_string()),
                    StreamTerminal::TimedOut => Some(crate::tr!("Query timed out")),
                    StreamTerminal::Loading | StreamTerminal::Complete | StreamTerminal::Cancelled => None,
                },
                StatementOutcomeKind::NotRun | StatementOutcomeKind::Rows(_) => None,
            }),
            rows: outcomes.iter().filter_map(rows_in).sum(),
        }
    }
}

pub(crate) enum ScriptRunResult {
    Completed(Vec<StatementOutcome>),
    Streamed(StreamTerminal),
    Cancelled,
    TimedOut,
}

pub(crate) enum StreamUpdate {
    Started {
        identity: StatementIdentity,
        sql_preview: String,
        sql: String,
        params: Vec<tablepro_core::Value>,
    },
    Page {
        sequence: u64,
        page: std::sync::Arc<QueryResult>,
    },
}

pub(crate) struct StatementRun<'a, S> {
    pub(crate) target: super::session_mode::StatementTarget,
    pub(crate) statements: Vec<String>,
    pub(crate) driver_id: &'a str,
    pub(crate) parameter_values: &'a std::collections::HashMap<String, tablepro_core::Value>,
    pub(crate) control: &'a OperationControl,
    pub(crate) error_policy: BatchErrorPolicy,
    pub(crate) settings_check: Option<LexicalSettings>,
    pub(crate) succeeded: S,
}

#[cfg(test)]
pub(crate) async fn run_statements(
    target: super::session_mode::StatementTarget,
    statements: Vec<String>,
    driver_id: &str,
    parameter_values: &std::collections::HashMap<String, tablepro_core::Value>,
    control: &OperationControl,
    error_policy: BatchErrorPolicy,
    succeeded: impl Fn(&str),
) -> ScriptRunResult {
    run_statements_with_stream(
        StatementRun {
            target,
            statements,
            driver_id,
            parameter_values,
            control,
            error_policy,
            settings_check: None,
            succeeded,
        },
        |_| async { false },
    )
    .await
}

pub(crate) async fn run_statements_with_stream<S, F, Fut>(run: StatementRun<'_, S>, stream_update: F) -> ScriptRunResult
where
    S: Fn(&str),
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    crate::services::approval_wait::track(run_tracked_statements(run, stream_update)).await
}

async fn run_tracked_statements<S, F, Fut>(run: StatementRun<'_, S>, mut stream_update: F) -> ScriptRunResult
where
    S: Fn(&str),
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    let StatementRun {
        target,
        statements,
        driver_id,
        parameter_values,
        control,
        error_policy,
        settings_check,
        succeeded,
    } = run;
    let (single_statement, stops_on_error) = (statements.len() == 1, error_policy == BatchErrorPolicy::StopScript);
    let last_index = statements.len().saturating_sub(1);
    let mut out = Vec::with_capacity(statements.len());
    let mut skip = None;
    for (statement_index, sql) in statements.into_iter().enumerate() {
        let identity = statement_identity(statement_index, &sql);
        let preview = sql_preview(&sql);
        if let Some(reason) = skip.replace(None) {
            out.push(skipped_outcome(identity, preview, reason));
            continue;
        }
        let (started, waited_before) = (std::time::Instant::now(), crate::services::approval_wait::waited());
        let bound = match bind_statement_for_run(&sql, driver_id, parameter_values, identity, preview.clone()) {
            Ok(bound) => bound,
            Err(reason) => {
                out.push(*reason);
                skip = stops_on_error.then_some(None);
                continue;
            }
        };
        let attempt = StreamAttempt {
            target: &target,
            single_statement,
            driver_id,
            bound_sql: &bound.sql,
            bound_params: &bound.values,
            identity,
            preview: preview.clone(),
            sql: &sql,
            started,
            control,
        };
        let kind = match run_statement(attempt, &mut stream_update, &succeeded).await {
            Ok(kind) => kind,
            Err(Halt::Finished(result)) => return result,
            Err(Halt::Failed(outcome)) => {
                out.push(*outcome);
                return ScriptRunResult::Completed(out);
            }
        };
        skip = (stops_on_error && matches!(kind, StatementOutcomeKind::Error(_))).then_some(None);
        out.push(statement_outcome(identity, preview, started, waited_before, kind));
        if skip.is_none() && statement_index < last_index {
            match lexical_settings_change(&target, settings_check, control).await {
                Ok(change) => skip = change.map(Some),
                Err(result) => return result,
            }
        }
    }
    ScriptRunResult::Completed(out)
}

fn skipped_outcome(identity: StatementIdentity, preview: String, reason: Option<String>) -> StatementOutcome {
    match reason {
        Some(reason) => StatementOutcome {
            kind: StatementOutcomeKind::Error(reason.into()),
            ..not_run_outcome(identity, preview)
        },
        None => not_run_outcome(identity, preview),
    }
}

enum Halt {
    Finished(ScriptRunResult),
    Failed(Box<StatementOutcome>),
}

async fn run_statement<F, Fut>(
    attempt: StreamAttempt<'_>,
    stream_update: &mut F,
    succeeded: &impl Fn(&str),
) -> Result<StatementOutcomeKind, Halt>
where
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    let (target, bound_sql, bound_params, sql, control) = (
        attempt.target,
        attempt.bound_sql,
        attempt.bound_params,
        attempt.sql,
        attempt.control,
    );
    match stream_statement_if_supported(attempt, stream_update, succeeded).await {
        Ok(Some(result)) => return Err(Halt::Finished(result)),
        Ok(None) => {}
        Err(outcome) => return Err(Halt::Failed(outcome)),
    }
    query_statement(target, bound_sql, bound_params, sql, control, succeeded)
        .await
        .map_err(Halt::Finished)
}

async fn lexical_settings_change(
    target: &super::session_mode::StatementTarget,
    expected: Option<LexicalSettings>,
    control: &OperationControl,
) -> Result<Option<String>, ScriptRunResult> {
    let Some(expected) = expected else {
        return Ok(None);
    };
    match target.lexical_settings(control).await {
        Ok(current) if current.is_none_or(|current| current == expected) => Ok(None),
        Ok(_) => Ok(Some(crate::tr!(
            "Not run: the previous statement changed how this session reads strings, so the rest of the script \
             would split differently. Run the remaining statements again."
        ))),
        Err(DriverError::Cancelled) => Err(ScriptRunResult::Cancelled),
        Err(DriverError::TimedOut) => Err(ScriptRunResult::TimedOut),
        Err(error) => Ok(Some(
            crate::tr!("Not run: could not confirm how this session reads strings: {error}")
                .replace("{error}", &crate::services::error_text::driver_message(&error)),
        )),
    }
}

fn not_run_outcome(identity: StatementIdentity, preview: String) -> StatementOutcome {
    StatementOutcome {
        identity,
        sql_preview: preview,
        elapsed_ms: 0,
        kind: StatementOutcomeKind::NotRun,
        pinned: false,
    }
}

fn statement_outcome(
    identity: StatementIdentity,
    preview: String,
    started: std::time::Instant,
    waited_before: std::time::Duration,
    kind: StatementOutcomeKind,
) -> StatementOutcome {
    StatementOutcome {
        identity,
        sql_preview: preview,
        elapsed_ms: elapsed_without_approval_wait(started, waited_before),
        kind,
        pinned: false,
    }
}

fn elapsed_without_approval_wait(started: std::time::Instant, waited_before: std::time::Duration) -> u128 {
    started
        .elapsed()
        .saturating_sub(crate::services::approval_wait::waited().saturating_sub(waited_before))
        .as_millis()
}

fn bind_statement_for_run(
    sql: &str,
    driver_id: &str,
    parameter_values: &std::collections::HashMap<String, tablepro_core::Value>,
    identity: StatementIdentity,
    preview: String,
) -> Result<crate::services::query_parameters::BoundStatement, Box<StatementOutcome>> {
    crate::services::query_parameters::bind_statement(sql, driver_id, parameter_values).map_err(|error| {
        Box::new(StatementOutcome {
            identity,
            sql_preview: preview,
            elapsed_ms: 0,
            kind: StatementOutcomeKind::Error(crate::ui::parameters_dialog::error_message(error).into()),
            pinned: false,
        })
    })
}

async fn query_statement(
    target: &super::session_mode::StatementTarget,
    bound_sql: &str,
    bound_params: &[tablepro_core::Value],
    sql: &str,
    control: &OperationControl,
    succeeded: &impl Fn(&str),
) -> Result<StatementOutcomeKind, ScriptRunResult> {
    match target.query(bound_sql, bound_params, control).await {
        Ok(result) => {
            succeeded(sql);
            Ok(StatementOutcomeKind::Rows(
                result.result_sets.into_iter().map(std::sync::Arc::new).collect(),
            ))
        }
        Err(DriverError::Cancelled) => Err(ScriptRunResult::Cancelled),
        Err(DriverError::TimedOut) => Err(ScriptRunResult::TimedOut),
        Err(error) => Ok(StatementOutcomeKind::Error(failure_message(&error, sql, bound_sql))),
    }
}

struct StreamAttempt<'a> {
    target: &'a super::session_mode::StatementTarget,
    single_statement: bool,
    driver_id: &'a str,
    bound_sql: &'a str,
    bound_params: &'a [tablepro_core::Value],
    identity: StatementIdentity,
    preview: String,
    sql: &'a str,
    started: std::time::Instant,
    control: &'a OperationControl,
}

async fn stream_statement_if_supported<F, Fut>(
    attempt: StreamAttempt<'_>,
    stream_update: &mut F,
    succeeded: &impl Fn(&str),
) -> Result<Option<ScriptRunResult>, Box<StatementOutcome>>
where
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    if !attempt.single_statement || !stream_candidate(attempt.bound_sql, attempt.driver_id) {
        return Ok(None);
    }
    match attempt
        .target
        .open_query_cursor(attempt.bound_sql, attempt.bound_params, attempt.control)
        .await
    {
        Ok(Some(cursor)) => Ok(Some(
            run_streamed_statement(
                StreamExecution {
                    cursor,
                    identity: attempt.identity,
                    preview: attempt.preview,
                    bound_sql: attempt.bound_sql.into(),
                    bound_params: attempt.bound_params.to_vec(),
                    sql: attempt.sql,
                    control: attempt.control,
                },
                stream_update,
                succeeded,
            )
            .await,
        )),
        Ok(None) => Ok(None),
        Err(DriverError::Cancelled) => Ok(Some(ScriptRunResult::Cancelled)),
        Err(DriverError::TimedOut) => Ok(Some(ScriptRunResult::TimedOut)),
        Err(error) => Err(Box::new(StatementOutcome {
            identity: attempt.identity,
            sql_preview: attempt.preview,
            elapsed_ms: attempt.started.elapsed().as_millis(),
            kind: StatementOutcomeKind::Error(failure_message(&error, attempt.sql, attempt.bound_sql)),
            pinned: false,
        })),
    }
}

fn stream_candidate(sql: &str, driver_id: &str) -> bool {
    if driver_id != "postgres" {
        return false;
    }
    tablepro_policy::classify(sql, driver_id).is_single_read()
        && super::stream_functions::calls_only_read_only_functions(sql)
}

struct StreamExecution<'a> {
    cursor: super::session_mode::StatementCursor,
    identity: StatementIdentity,
    preview: String,
    bound_sql: String,
    bound_params: Vec<tablepro_core::Value>,
    sql: &'a str,
    control: &'a OperationControl,
}

async fn run_streamed_statement<F, Fut>(
    execution: StreamExecution<'_>,
    stream_update: &mut F,
    succeeded: &impl Fn(&str),
) -> ScriptRunResult
where
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    let StreamExecution {
        cursor,
        identity,
        preview,
        bound_sql,
        bound_params,
        sql,
        control,
    } = execution;
    let sent = bound_sql.clone();
    let started = stream_update(StreamUpdate::Started {
        identity,
        sql_preview: preview,
        sql: bound_sql,
        params: bound_params,
    })
    .await;
    if !started {
        finish_stream_cursor(cursor, true).await;
        return ScriptRunResult::Streamed(StreamTerminal::Cancelled);
    }
    fetch_stream_pages(cursor, (sql, &sent), control, stream_update, succeeded).await
}

async fn fetch_stream_pages<F, Fut>(
    cursor: super::session_mode::StatementCursor,
    (sql, sent): (&str, &str),
    control: &OperationControl,
    stream_update: &mut F,
    succeeded: &impl Fn(&str),
) -> ScriptRunResult
where
    F: FnMut(StreamUpdate) -> Fut,
    Fut: Future<Output = bool>,
{
    let mut sequence = 0;
    loop {
        let page = match cursor.fetch_page(control).await {
            Ok(page) => page,
            Err(DriverError::Cancelled) => {
                finish_stream_cursor(cursor, false).await;
                return ScriptRunResult::Streamed(StreamTerminal::Cancelled);
            }
            Err(DriverError::TimedOut) => {
                finish_stream_cursor(cursor, false).await;
                return ScriptRunResult::Streamed(StreamTerminal::TimedOut);
            }
            Err(error) => {
                let message = failure_message(&error, sql, sent);
                finish_stream_cursor(cursor, false).await;
                return ScriptRunResult::Streamed(StreamTerminal::Failed(message));
            }
        };
        let has_next_page = page.has_next_page;
        let truncated = page.result.truncated;
        if !stream_update(StreamUpdate::Page {
            sequence,
            page: std::sync::Arc::new(page.result),
        })
        .await
        {
            finish_stream_cursor(cursor, true).await;
            return ScriptRunResult::Streamed(StreamTerminal::Cancelled);
        }
        sequence = sequence.saturating_add(1);
        if truncated {
            finish_stream_cursor(cursor, true).await;
            return ScriptRunResult::Streamed(StreamTerminal::Failed(
                crate::tr!("A result page exceeded the query result limit. The result is incomplete.").into(),
            ));
        }
        if !has_next_page {
            if let Err(error) = cursor.finish(true).await {
                return ScriptRunResult::Streamed(StreamTerminal::Failed(
                    crate::services::error_text::driver_message(&error).into(),
                ));
            }
            succeeded(sql);
            return ScriptRunResult::Streamed(StreamTerminal::Complete);
        }
    }
}

async fn finish_stream_cursor(cursor: super::session_mode::StatementCursor, close_cursor: bool) {
    if let Err(error) = cursor.finish(close_cursor).await {
        crate::services::driver_diagnostics::warn_driver_cleanup(&error, "finish");
    }
}

fn statement_identity(statement_index: usize, sql: &str) -> StatementIdentity {
    let mut digest = Sha256::new();
    digest.update((statement_index as u64).to_be_bytes());
    digest.update((sql.len() as u64).to_be_bytes());
    digest.update(sql.as_bytes());
    StatementIdentity {
        statement_index,
        digest: digest.finalize().into(),
    }
}

fn failure_message(error: &DriverError, written: &str, sent: &str) -> super::StatementFailure {
    super::StatementFailure::located(error, written, sent)
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
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
) -> gtk::Widget {
    match &o.kind {
        StatementOutcomeKind::Rows(result_sets) if result_sets.len() > 1 => {
            build_multi_result_widget(o, result_sets, grid_sender, connection_id, database, settings_store)
        }
        StatementOutcomeKind::Rows(result_sets) if let Some(result) = result_sets.first() => build_result_set_widget(
            result,
            grid_sender,
            connection_id,
            database,
            settings_store,
            result_view_key(o.identity, 0),
        ),
        StatementOutcomeKind::Rows(_) => {
            let ms = o.elapsed_ms.to_string();
            let number = (o.identity.statement_index + 1).to_string();
            adw::StatusPage::builder()
                .title(crate::tr!("Statement {n} executed").replace("{n}", &number))
                .description(crate::tr!("No rows returned · {ms} ms").replace("{ms}", &ms))
                .icon_name("emblem-default-symbolic")
                .vexpand(true)
                .build()
                .upcast()
        }
        StatementOutcomeKind::Streamed(result) => {
            build_streamed_result_widget(o, result, grid_sender, connection_id, database, settings_store)
        }
        StatementOutcomeKind::Error(msg) => error_page(o.identity.statement_index, msg).upcast(),
        StatementOutcomeKind::NotRun => adw::StatusPage::builder()
            .title(crate::tr!("Statement {n} not run").replace("{n}", &(o.identity.statement_index + 1).to_string()))
            .description(crate::tr!("Skipped because an earlier statement failed."))
            .icon_name("media-playback-stop-symbolic")
            .vexpand(true)
            .build()
            .upcast(),
    }
}

fn build_streamed_result_widget(
    outcome: &StatementOutcome,
    result: &StreamedResult,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
) -> gtk::Widget {
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let page_switcher = gtk::Stack::builder().vexpand(true).hexpand(true).build();
    for (position, (page_index, page)) in result.page_indices.iter().copied().zip(&result.pages).enumerate() {
        let widget = build_stream_page_widget(
            page,
            grid_sender,
            connection_id,
            database.clone(),
            settings_store.clone(),
            result_view_key(outcome.identity, page_index as usize),
        );
        widget.set_widget_name(&super::stream_view::page_widget_name(page_index));
        page_switcher.add_titled(
            &widget,
            Some(widget.widget_name().as_str()),
            &stream_page_label(result, position),
        );
    }
    if let Some(page) = stream_terminal_page(result, outcome.identity.statement_index) {
        page_switcher.add_titled(&page, Some("status"), &crate::tr!("Status"));
    }
    if let Some(last) = page_switcher.last_child() {
        page_switcher.set_visible_child(&last);
    }
    let progress = gtk::Label::new(Some(&stream_progress_text(result)));
    progress.set_wrap(true);
    if matches!(result.terminal, StreamTerminal::Loading) {
        page_switcher.set_widget_name(super::stream_view::LIVE_PAGES);
        progress.set_widget_name(super::stream_view::LIVE_PROGRESS);
    }
    holder.append(&progress);
    if let Some(request) = result.export.clone() {
        let export = gtk::Button::with_label(&crate::tr!("Export all rows…"));
        export.add_css_class("flat");
        export.connect_clicked({
            let grid_sender = grid_sender.clone();
            move |_| {
                let _ = grid_sender.send(GridMsg::ExportStreamedResults(request.clone()));
            }
        });
        holder.append(&export);
        holder.append(&gtk::Label::new(Some(&crate::tr!(
            "The query will run again through a guarded cursor."
        ))));
    }
    holder.append(&super::stream_view::build_pager(&page_switcher));
    holder.append(&page_switcher);
    holder.upcast()
}

pub(super) fn stream_progress_text(result: &StreamedResult) -> String {
    let rows = crate::trn!("Received {rows} row", "Received {rows} rows", result.total_rows)
        .replace("{rows}", &result.total_rows.to_string());
    let pages = crate::trn!("{pages} page", "{pages} pages", result.total_pages)
        .replace("{pages}", &result.total_pages.to_string());
    let received = format!("{rows} · {pages}");
    let retained: usize = result.pages.iter().map(|page| page.rows.len()).sum();
    if retained == result.total_rows {
        return received;
    }
    let notice = crate::tr!("Retained rows {start}-{end}. Earlier rows are no longer available.")
        .replace(
            "{start}",
            &result.total_rows.saturating_sub(retained).saturating_add(1).to_string(),
        )
        .replace("{end}", &result.total_rows.to_string());
    format!("{received}\n{notice}")
}

pub(super) fn stream_page_label(result: &StreamedResult, position: usize) -> String {
    let Some(page) = result.pages.get(position).filter(|page| !page.rows.is_empty()) else {
        return crate::tr!("Rows 0");
    };
    let retained: usize = result.pages.iter().map(|page| page.rows.len()).sum();
    let preceding: usize = result.pages.iter().take(position).map(|page| page.rows.len()).sum();
    let start = result
        .total_rows
        .saturating_sub(retained)
        .saturating_add(preceding)
        .saturating_add(1);
    let end = start.saturating_add(page.rows.len().saturating_sub(1));
    crate::tr!("Rows {start}-{end}")
        .replace("{start}", &start.to_string())
        .replace("{end}", &end.to_string())
}

fn stream_terminal_page(result: &StreamedResult, statement_index: usize) -> Option<gtk::Widget> {
    match &result.terminal {
        StreamTerminal::Loading | StreamTerminal::Complete => None,
        StreamTerminal::Failed(message) => Some(error_page(statement_index, message).upcast()),
        StreamTerminal::Cancelled => Some(
            adw::StatusPage::builder()
                .title(crate::tr!("Query cancelled"))
                .description(crate::tr!("Only retained rows remain available."))
                .icon_name("process-stop-symbolic")
                .vexpand(true)
                .build()
                .upcast(),
        ),
        StreamTerminal::TimedOut => Some(
            adw::StatusPage::builder()
                .title(crate::tr!("Query timed out"))
                .description(crate::tr!("Only retained rows remain available."))
                .icon_name("dialog-warning-symbolic")
                .vexpand(true)
                .build()
                .upcast(),
        ),
    }
}

fn build_multi_result_widget(
    outcome: &StatementOutcome,
    result_sets: &[std::sync::Arc<tablepro_core::QueryResult>],
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
) -> gtk::Widget {
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
        let widget = build_result_set_widget(
            result,
            grid_sender,
            connection_id,
            database.clone(),
            settings_store.clone(),
            result_view_key(outcome.identity, index),
        );
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

fn error_page(idx: usize, message: &super::StatementFailure) -> gtk::Box {
    let holder = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .vexpand(true)
        .build();
    let title = gtk::Label::builder()
        .label(crate::tr!("Statement {n} failed").replace("{n}", &(idx + 1).to_string()))
        .css_classes(["title-3"])
        .xalign(0.0)
        .wrap(true)
        .build();
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .halign(gtk::Align::Start)
        .min_children_per_line(1)
        .max_children_per_line(2)
        .column_spacing(6)
        .row_spacing(4)
        .build();
    let copy = gtk::Button::with_label(&crate::tr!("Copy error"));
    let text = message.to_string();
    copy.connect_clicked(move |button| button.clipboard().set_text(&text));
    actions.insert(&copy, -1);
    let audit = gtk::Button::builder()
        .label(crate::tr!("View in Audit Log"))
        .action_name("win.show-audit")
        .css_classes(["pill", "flat"])
        .build();
    actions.insert(&audit, -1);
    if let Some(button) = message.navigation_button() {
        actions.insert(&button, -1);
    }
    let description = gtk::Label::builder()
        .label(message.as_ref())
        .selectable(true)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::WordChar)
        .xalign(0.0)
        .yalign(0.0)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .child(&description)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .build();
    holder.append(&title);
    holder.append(&actions);
    holder.append(&scroll);
    holder
}

pub(super) fn build_stream_page_widget(
    result: &std::sync::Arc<tablepro_core::QueryResult>,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
    settings_key: ResultViewKey,
) -> gtk::Widget {
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.set_vexpand(true);
    let result = result.clone();
    let grid_sender = grid_sender.clone();
    let build = std::rc::Rc::new(std::cell::RefCell::new(Some(move || {
        build_result_set_widget(
            &result,
            &grid_sender,
            connection_id,
            database,
            settings_store,
            settings_key,
        )
    })));
    let scheduled = std::rc::Rc::new(std::cell::Cell::new(false));
    holder.connect_map(move |holder| {
        if build.borrow().is_none() || scheduled.replace(true) {
            return;
        }
        let build = std::rc::Rc::downgrade(&build);
        let scheduled = scheduled.clone();
        let holder = holder.downgrade();
        gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(50), move || {
            scheduled.set(false);
            let Some(holder) = holder.upgrade().filter(|holder| holder.is_mapped()) else {
                return;
            };
            let Some(build) = build.upgrade() else { return };
            if let Some(build) = build.borrow_mut().take() {
                holder.append(&build());
            }
        });
    });
    holder.upcast()
}

pub(super) fn build_result_set_widget(
    result: &std::sync::Arc<tablepro_core::QueryResult>,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
    settings_key: ResultViewKey,
) -> gtk::Widget {
    if result.columns.is_empty() {
        return adw::StatusPage::builder()
            .title(crate::tr!("No rows returned"))
            .icon_name("emblem-default-symbolic")
            .vexpand(true)
            .build()
            .upcast();
    }
    let local_result_view =
        super::super::grid::local_filter::LocalResultView::new(result.clone(), settings_store, settings_key);
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
            local_result_sort: true,
            local_result_view: Some(local_result_view.clone()),
            sortable_result_columns: crate::ui::grid::sortable_result_columns(result),
            ..Default::default()
        },
        None,
        database,
    );
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.append(&local_result_view.controls());
    holder.append(
        &gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build(),
    );
    holder.upcast()
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

fn outcome_tab_label(o: &StatementOutcome) -> String {
    if o.pinned {
        return pinned_tab_label(o);
    }
    let n = (o.identity.statement_index + 1).to_string();
    let Some(statement) = statement_subject(&o.sql_preview) else {
        return match &o.kind {
            StatementOutcomeKind::Rows(sets) => crate::tr!("Result {n} ({rows})")
                .replace("{n}", &n)
                .replace("{rows}", &result_rows(sets).to_string()),
            StatementOutcomeKind::Streamed(result) => crate::tr!("Result {n} ({rows})")
                .replace("{n}", &n)
                .replace("{rows}", &result.total_rows.to_string()),
            StatementOutcomeKind::Error(_) => crate::tr!("Result {n} (error)").replace("{n}", &n),
            StatementOutcomeKind::NotRun => crate::tr!("Result {n} (skipped)").replace("{n}", &n),
        };
    };
    match &o.kind {
        StatementOutcomeKind::Rows(sets) => crate::tr!("{n} · {statement} ({rows})")
            .replace("{n}", &n)
            .replace("{statement}", &statement)
            .replace("{rows}", &result_rows(sets).to_string()),
        StatementOutcomeKind::Streamed(result) => crate::tr!("{n} · {statement} ({rows})")
            .replace("{n}", &n)
            .replace("{statement}", &statement)
            .replace("{rows}", &result.total_rows.to_string()),
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
        StatementOutcomeKind::Streamed(result) => result.total_rows.to_string(),
        StatementOutcomeKind::Error(_) | StatementOutcomeKind::NotRun => String::new(),
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

pub(super) fn first_failure(outcomes: &[StatementOutcome]) -> Option<usize> {
    outcomes.iter().position(|outcome| match &outcome.kind {
        StatementOutcomeKind::Error(_) => true,
        StatementOutcomeKind::Streamed(result) => {
            matches!(result.terminal, StreamTerminal::Failed(_) | StreamTerminal::TimedOut)
        }
        _ => false,
    })
}

fn build_result_drop_down(stack: &adw::ViewStack, outcomes: &[StatementOutcome]) -> gtk::DropDown {
    let labels: Vec<String> = outcomes.iter().map(outcome_tab_label).collect();
    let label_refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let drop_down = gtk::DropDown::from_strings(&label_refs);
    drop_down.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Statement result"))]);
    let first_error = first_failure(outcomes).unwrap_or(0);
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
    settings_store: LocalResultSettingsStore,
) {
    settings_store.retain(&result_view_keys(outcomes));
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
        let widget = build_outcome_widget(&outcomes[0], grid_sender, connection_id, database, settings_store);
        holder.append(&widget);
        return;
    }
    let stack = adw::ViewStack::new();
    for (idx, o) in outcomes.iter().enumerate() {
        let widget = build_outcome_widget(o, grid_sender, connection_id, database.clone(), settings_store.clone());
        let icon = match &o.kind {
            StatementOutcomeKind::Rows(_) | StatementOutcomeKind::Streamed(_) => "view-grid-symbolic",
            StatementOutcomeKind::Error(_) => "dialog-error-symbolic",
            StatementOutcomeKind::NotRun => "emblem-synchronizing-symbolic",
        };
        let page = stack.add_titled_with_icon(&widget, Some(&format!("r{idx}")), &outcome_tab_label(o), icon);
        if !o.sql_preview.is_empty() {
            widget.set_tooltip_text(Some(&o.sql_preview));
            let _ = page;
        }
    }
    holder.append(&build_result_switcher(&stack, outcomes));
    holder.append(&stack);
    if let Some(err_idx) = first_failure(outcomes) {
        stack.set_visible_child_name(&format!("r{err_idx}"));
    }
}

pub(super) fn result_view_key(identity: StatementIdentity, result_set_index: usize) -> ResultViewKey {
    ResultViewKey {
        statement_identity: identity,
        result_set_index,
    }
}

fn result_view_keys(outcomes: &[StatementOutcome]) -> std::collections::HashSet<ResultViewKey> {
    outcomes
        .iter()
        .flat_map(|outcome| match &outcome.kind {
            StatementOutcomeKind::Rows(result_sets) => result_sets
                .iter()
                .enumerate()
                .map(|(index, _)| result_view_key(outcome.identity, index))
                .collect::<Vec<_>>(),
            StatementOutcomeKind::Streamed(result) => result
                .page_indices
                .iter()
                .map(|page_index| result_view_key(outcome.identity, *page_index as usize))
                .collect::<Vec<_>>(),
            StatementOutcomeKind::Error(_) | StatementOutcomeKind::NotRun => Vec::new(),
        })
        .collect()
}

#[cfg(test)]
#[path = "outcomes/lexing_tests.rs"]
mod lexing_tests;
#[cfg(test)]
#[path = "outcomes/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "outcomes/lifetime_tests.rs"]
mod lifetime_tests;
