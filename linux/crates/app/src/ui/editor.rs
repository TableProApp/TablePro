use std::time::SystemTime;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::prelude::*;
use relm4::{adw, gtk};
use sourceview5::prelude::*;
use tokio_util::sync::CancellationToken;

use tablepro_core::QueryResult;
use tablepro_storage::query_history::{self, NewEntry, Outcome};

use super::grid::{TabGridContext, build_column_view};
use crate::services::database_service::{self, ConnectionMetadata};

pub struct SqlEditor {
    source_view: sourceview5::View,
    run_button: gtk::Button,
    cancel_button: gtk::Button,
    running_spinner: gtk::Spinner,
    results_holder: gtk::Box,
    status: gtk::Label,
    cancel_token: Option<CancellationToken>,
    executing_sql: Option<String>,
    executing_metadata: Option<ConnectionMetadata>,
    executing_started_at: Option<SystemTime>,
}

pub struct SqlEditorInit {
    pub schema_buffer: gtk::TextBuffer,
    pub initial_query: Option<String>,
}

/// One statement's outcome inside a multi-statement script. The
/// editor renders these as sub-tabs of the results pane so a user
/// running a migration / ETL script sees every step's result, not
/// just the last one. `sql_preview` is the leading ~60 chars of the
/// statement text used for the tab tooltip.
#[derive(Debug, Clone)]
pub struct StatementOutcome {
    pub sql_preview: String,
    pub elapsed_ms: u128,
    pub kind: StatementOutcomeKind,
}

#[derive(Debug, Clone)]
pub enum StatementOutcomeKind {
    /// Statement returned a result set (SELECT, RETURNING, etc.).
    /// `rows_affected` is `None` because driver `query` doesn't
    /// distinguish; for non-SELECT the rows vec is empty and we
    /// surface a "executed" status instead of a row count.
    Rows(QueryResult),
    /// Statement failed; remaining statements are NotRun.
    Error(String),
    /// Statement was queued behind a failure or cancellation —
    /// never sent to the driver.
    NotRun,
}

#[derive(Debug)]
pub enum SqlEditorInput {
    Run,
    Cancel,
    /// One outcome per statement in the script. Single-statement
    /// scripts produce a Vec of len 1; multi-statement scripts a
    /// Vec of len N. The editor decides the rendering (single grid
    /// vs. sub-tabs) based on Vec length.
    ShowOutcomes(Vec<StatementOutcome>),
    ShowCancelled,
    /// Query exceeded the configured wall-clock timeout. Treated
    /// like a manual cancel from the user's perspective but with
    /// a different status / history-record reason.
    ShowTimedOut(u32),
    ReplaceQuery(String),
}

#[derive(Debug)]
pub enum SqlEditorOutput {
    RunStateChanged(bool),
    QueryChanged(String),
}

#[relm4::component(pub)]
impl SimpleComponent for SqlEditor {
    type Init = SqlEditorInit;
    type Input = SqlEditorInput;
    type Output = SqlEditorOutput;

    view! {
        adw::ToolbarView {
            // Top bar: cursor + status pushed right by an empty
            // spacer; Run on the trailing edge with Cancel beside it
            // when a query is in flight. The decorative "SQL" label
            // was removed — the tab title carries that context, and
            // GNOME Builder / Text Editor don't label their editor
            // areas by language either. Cancel is flat (not
            // destructive-action) because cancelling a running query
            // doesn't destroy data; .destructive-action is reserved
            // for irreversible operations.
            add_top_bar = &gtk::Box {
                set_orientation: gtk::Orientation::Horizontal,
                set_spacing: 8,
                set_margin_top: 8,
                set_margin_bottom: 8,
                set_margin_start: 8,
                set_margin_end: 8,

                gtk::Box {
                    set_hexpand: true,
                },

                #[name = "cursor_info"]
                gtk::Label {
                    set_halign: gtk::Align::End,
                    add_css_class: "dim-label",
                    add_css_class: "monospace",
                    set_margin_end: 8,
                },

                #[name = "running_spinner"]
                gtk::Spinner {
                    set_visible: false,
                    set_spinning: true,
                    set_size_request: (20, 20),
                },

                #[name = "status"]
                gtk::Label {
                    set_halign: gtk::Align::End,
                    add_css_class: "dim-label",
                },

                #[name = "cancel_button"]
                gtk::Button {
                    set_label: &crate::tr!("Cancel"),
                    set_tooltip_text: Some(crate::tr!("Cancel running query (Esc)").as_str()),
                    set_visible: false,
                    add_css_class: "flat",
                    connect_clicked => SqlEditorInput::Cancel,
                },

                #[name = "run_button"]
                gtk::Button {
                    set_label: &crate::tr!("Run"),
                    set_tooltip_text: Some(crate::tr!("Run query (Ctrl+Return)").as_str()),
                    add_css_class: "suggested-action",
                    connect_clicked => SqlEditorInput::Run,
                },
            },

            #[wrap(Some)]
            set_content = &gtk::Paned {
                set_orientation: gtk::Orientation::Vertical,
                set_position: 280,
                set_vexpand: true,
                set_hexpand: true,

                #[wrap(Some)]
                set_start_child = &gtk::ScrolledWindow {
                    set_min_content_height: 200,

                    #[wrap(Some)]
                    #[name = "source_view"]
                    set_child = &sourceview5::View {
                        set_show_line_numbers: true,
                        set_monospace: true,
                        set_auto_indent: true,
                        set_highlight_current_line: true,
                        set_tab_width: 4,
                        set_top_margin: 8,
                        set_bottom_margin: 8,
                        set_left_margin: 8,
                        set_right_margin: 8,
                    },
                },

                #[wrap(Some)]
                #[name = "results_holder"]
                set_end_child = &gtk::Box {
                    set_orientation: gtk::Orientation::Vertical,
                },
            },
        }
    }

    fn init(init: Self::Init, _root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let widgets = view_output!();

        let lang_manager = sourceview5::LanguageManager::default();
        let initial_text = init.initial_query.unwrap_or_else(|| "SELECT 1;".to_string());
        if let Some(lang) = lang_manager.language("sql") {
            let buffer = sourceview5::Buffer::with_language(&lang);
            buffer.set_text(&initial_text);
            widgets.source_view.set_buffer(Some(&buffer));
        } else {
            widgets.source_view.buffer().set_text(&initial_text);
        }
        apply_editor_scheme(&widgets.source_view);
        let view_for_theme = widgets.source_view.clone();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            apply_editor_scheme(&view_for_theme);
        });

        let font_size = crate::services::preferences::load().editor_font_size;
        apply_editor_font_size(&widgets.source_view, font_size);

        let provider = sourceview5::CompletionWords::new(Some("SQL"));
        provider.register(&init.schema_buffer);
        if let Ok(view_buffer) = widgets.source_view.buffer().downcast::<sourceview5::Buffer>() {
            provider.register(&view_buffer);
        }
        let completion = widgets.source_view.completion();
        completion.add_provider(&provider);

        let cursor_info = widgets.cursor_info.clone();
        let view_for_cursor = widgets.source_view.clone();
        let update_cursor = move || {
            let buffer = view_for_cursor.buffer();
            let mark = buffer.get_insert();
            let iter = buffer.iter_at_mark(&mark);
            let line = iter.line() + 1;
            let col = iter.line_offset() + 1;
            cursor_info.set_label(&format!("Ln {line}, Col {col}"));
        };
        update_cursor();
        widgets
            .source_view
            .buffer()
            .connect_cursor_position_notify(move |_| update_cursor());

        let view_for_change = widgets.source_view.clone();
        let sender_for_change = sender.clone();
        widgets.source_view.buffer().connect_changed(move |_| {
            let buffer = view_for_change.buffer();
            let (start, end) = buffer.bounds();
            let text = buffer.text(&start, &end, false).to_string();
            let _ = sender_for_change.output(SqlEditorOutput::QueryChanged(text));
        });

        let run_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>Return").expect("valid trigger"))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::Run);
                    glib::Propagation::Stop
                }
            }))
            .build();
        // Esc cancels a running query. The editor tab isn't a dialog
        // so Esc is otherwise unbound, and keyboard parity with the
        // Run shortcut matters most when the user is trying to stop
        // a runaway query and shouldn't have to hunt the small flat
        // Cancel button. The Cancel handler no-ops when nothing is
        // running, so binding unconditionally is safe.
        let cancel_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Escape").expect("valid trigger"))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::Cancel);
                    glib::Propagation::Stop
                }
            }))
            .build();
        let controller = gtk::ShortcutController::new();
        controller.add_shortcut(run_shortcut);
        controller.add_shortcut(cancel_shortcut);
        widgets.source_view.add_controller(controller);

        let drop_target = gtk::DropTarget::new(gtk::gio::File::static_type(), gtk::gdk::DragAction::COPY);
        let view_for_drop = widgets.source_view.clone();
        drop_target.connect_drop(move |_, value, _, _| {
            if let Ok(file) = value.get::<gtk::gio::File>()
                && let Some(path) = file.path()
                && let Ok(text) = std::fs::read_to_string(&path)
            {
                let buffer = view_for_drop.buffer();
                let (start, end) = buffer.bounds();
                let existing_empty = buffer.text(&start, &end, false).trim().is_empty();
                if existing_empty {
                    // Empty buffer: replace wholesale — most natural
                    // for "open this SQL file in the editor".
                    buffer.set_text(&text);
                } else {
                    // Non-empty buffer: insert at cursor. Replacing
                    // would silently destroy whatever the user had
                    // typed, which fails GNOME Builder / Text Editor
                    // expectations for drag-and-drop. Insert is
                    // additive and undoable via Ctrl+Z.
                    buffer.insert_at_cursor(&text);
                }
                return true;
            }
            false
        });
        widgets.source_view.add_controller(drop_target);

        let model = SqlEditor {
            source_view: widgets.source_view.clone(),
            run_button: widgets.run_button.clone(),
            cancel_button: widgets.cancel_button.clone(),
            running_spinner: widgets.running_spinner.clone(),
            results_holder: widgets.results_holder.clone(),
            status: widgets.status.clone(),
            cancel_token: None,
            executing_sql: None,
            executing_metadata: None,
            executing_started_at: None,
        };
        ComponentParts { model, widgets }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            SqlEditorInput::Run => {
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, false).to_string();
                let trimmed = sql.trim().to_string();
                if trimmed.is_empty() {
                    self.status.set_label(&crate::tr!("empty query"));
                    return;
                }

                let conn = match database_service::instance().active() {
                    Some(c) => c,
                    None => {
                        self.status.set_label(&crate::tr!("no active connection"));
                        return;
                    }
                };

                if let Some(prev) = self.cancel_token.take() {
                    prev.cancel();
                }
                let token = CancellationToken::new();
                self.cancel_token = Some(token.clone());

                self.run_button.set_sensitive(false);
                self.cancel_button.set_visible(true);
                self.running_spinner.set_visible(true);
                self.status.set_label(&crate::tr!("Running…"));
                clear_box(&self.results_holder);
                let _ = sender.output(SqlEditorOutput::RunStateChanged(true));

                self.executing_sql = Some(trimmed.clone());
                self.executing_metadata = database_service::instance().active_metadata();
                self.executing_started_at = Some(SystemTime::now());

                let timeout_secs = crate::services::preferences::load().query_timeout_secs;
                let sender_clone = sender.clone();
                sender.command(move |_, shutdown| {
                    shutdown
                        .register(async move {
                            let statements = split_sql_statements(&trimmed);
                            // A `query_timeout_secs == 0` user opt-out
                            // turns the timeout branch off by holding a
                            // future that never resolves. Otherwise the
                            // tokio sleep races against `cancelled()`
                            // and `run_statements()`; first to finish
                            // wins.
                            let timeout: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
                                if timeout_secs > 0 {
                                    Box::pin(tokio::time::sleep(std::time::Duration::from_secs(timeout_secs as u64)))
                                } else {
                                    Box::pin(std::future::pending::<()>())
                                };
                            // The cancel token is the editor's own
                            // signal channel — the driver does not
                            // subscribe to it (sqlx has no future-
                            // drop cancellation hook for Postgres /
                            // MySQL). When the timeout wins, we
                            // *also* fire `token.cancel()` so any
                            // outer logic (pool shutdown, connection
                            // monitor) sees the same "this query is
                            // abandoned" signal as a manual Cancel,
                            // and the future drops on the next poll.
                            // Even with this, the underlying driver
                            // call may keep running on the server
                            // until the network layer notices the
                            // dropped read; users on long timeouts
                            // should restart the connection.
                            let token_for_timeout = token.clone();
                            let msg = tokio::select! {
                                biased;
                                _ = token.cancelled() => SqlEditorInput::ShowCancelled,
                                _ = timeout => {
                                    token_for_timeout.cancel();
                                    SqlEditorInput::ShowTimedOut(timeout_secs)
                                }
                                outcomes = run_statements(conn, statements) => {
                                    let total_ms: u128 = outcomes.iter().map(|o| o.elapsed_ms).sum();
                                    let n_ok = outcomes
                                        .iter()
                                        .filter(|o| matches!(o.kind, StatementOutcomeKind::Rows(_)))
                                        .count();
                                    let n_err = outcomes
                                        .iter()
                                        .filter(|o| matches!(o.kind, StatementOutcomeKind::Error(_)))
                                        .count();
                                    tracing::info!(n_ok, n_err, total_ms, "script run complete");
                                    SqlEditorInput::ShowOutcomes(outcomes)
                                }
                            };
                            sender_clone.input(msg);
                        })
                        .drop_on_shutdown()
                });
            }

            SqlEditorInput::Cancel => {
                if let Some(token) = self.cancel_token.take() {
                    token.cancel();
                }
            }

            SqlEditorInput::ShowOutcomes(outcomes) => {
                self.cancel_token = None;
                self.run_button.set_sensitive(true);
                self.cancel_button.set_visible(false);
                self.running_spinner.set_visible(false);
                let _ = sender.output(SqlEditorOutput::RunStateChanged(false));

                let total_ms: u128 = outcomes.iter().map(|o| o.elapsed_ms).sum();
                let n_total = outcomes.len();
                let n_ok = outcomes
                    .iter()
                    .filter(|o| matches!(o.kind, StatementOutcomeKind::Rows(_)))
                    .count();
                let first_error = outcomes.iter().find_map(|o| match &o.kind {
                    StatementOutcomeKind::Error(msg) => Some(msg.clone()),
                    _ => None,
                });

                // History records the whole script as one entry.
                // rows_affected aggregates across SELECT outcomes
                // (NULL for scripts containing only DML).
                let total_rows: i64 = outcomes
                    .iter()
                    .filter_map(|o| match &o.kind {
                        StatementOutcomeKind::Rows(qr) => Some(qr.rows.len() as i64),
                        _ => None,
                    })
                    .sum();
                let history_outcome = match &first_error {
                    Some(msg) => Outcome::Error(msg.clone()),
                    None => Outcome::Success,
                };
                let rows_for_history = if total_rows > 0 { Some(total_rows) } else { None };
                self.record_history(total_ms as i64, rows_for_history, history_outcome);

                self.status
                    .set_label(&summary_label(n_total, n_ok, total_ms, first_error.is_some()));
                clear_box(&self.results_holder);
                render_outcomes(&self.results_holder, &outcomes);
            }

            SqlEditorInput::ShowCancelled => {
                self.cancel_token = None;
                self.run_button.set_sensitive(true);
                self.cancel_button.set_visible(false);
                self.running_spinner.set_visible(false);
                let _ = sender.output(SqlEditorOutput::RunStateChanged(false));
                let elapsed = self
                    .executing_started_at
                    .and_then(|t| SystemTime::now().duration_since(t).ok())
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
                self.record_history(elapsed, None, Outcome::Cancelled);
                self.status.set_label(&crate::tr!("cancelled"));
                clear_box(&self.results_holder);
                let cancelled_page = adw::StatusPage::builder()
                    .title(crate::tr!("Query cancelled"))
                    .description(crate::tr!("The running query was stopped."))
                    .icon_name("process-stop-symbolic")
                    .vexpand(true)
                    .build();
                self.results_holder.append(&cancelled_page);
            }

            SqlEditorInput::ShowTimedOut(secs) => {
                self.cancel_token = None;
                self.run_button.set_sensitive(true);
                self.cancel_button.set_visible(false);
                self.running_spinner.set_visible(false);
                let _ = sender.output(SqlEditorOutput::RunStateChanged(false));
                let elapsed = self
                    .executing_started_at
                    .and_then(|t| SystemTime::now().duration_since(t).ok())
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
                let secs_str = secs.to_string();
                let reason =
                    crate::tr!("Query exceeded the {n}s timeout configured in Preferences.").replace("{n}", &secs_str);
                self.record_history(elapsed, None, Outcome::Error(reason.clone()));
                self.status.set_label(&crate::tr!("timed out"));
                clear_box(&self.results_holder);
                let page = adw::StatusPage::builder()
                    .title(crate::tr!("Query timed out"))
                    .description(&reason)
                    .icon_name("dialog-warning-symbolic")
                    .vexpand(true)
                    .build();
                self.results_holder.append(&page);
            }

            SqlEditorInput::ReplaceQuery(text) => {
                self.source_view.buffer().set_text(&text);
            }
        }
    }
}

impl SqlEditor {
    fn record_history(&mut self, duration_ms: i64, rows_affected: Option<i64>, outcome: Outcome) {
        let (Some(query), Some(metadata), Some(started_at)) = (
            self.executing_sql.take(),
            self.executing_metadata.take(),
            self.executing_started_at.take(),
        ) else {
            return;
        };
        let entry = NewEntry {
            query,
            driver_id: metadata.driver_id,
            connection_id: metadata.id,
            connection_name: metadata.name,
            executed_at: started_at,
            duration_ms: Some(duration_ms),
            rows_affected,
            outcome,
        };
        relm4::spawn(async move {
            if let Err(e) = query_history::record(entry).await {
                tracing::warn!(error = %e, "history record failed");
            }
        });
    }
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

async fn run_statements(
    conn: std::sync::Arc<dyn tablepro_core::Connection>,
    statements: Vec<String>,
) -> Vec<StatementOutcome> {
    if statements.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(statements.len());
    let mut aborted = false;
    for sql in statements.into_iter() {
        let preview = sql_preview(&sql);
        if aborted {
            out.push(StatementOutcome {
                sql_preview: preview,
                elapsed_ms: 0,
                kind: StatementOutcomeKind::NotRun,
            });
            continue;
        }
        let started = std::time::Instant::now();
        let kind = match conn.query(&sql).await {
            Ok(qr) => StatementOutcomeKind::Rows(qr),
            Err(e) => {
                aborted = true;
                StatementOutcomeKind::Error(super::error_text::driver_message(&e))
            }
        };
        out.push(StatementOutcome {
            sql_preview: preview,
            elapsed_ms: started.elapsed().as_millis(),
            kind,
        });
    }
    out
}

/// First ~60 chars of `sql`, single-line, used for tab tooltips so
/// the user can tell sub-tabs apart on long scripts without reading
/// the editor.
fn sql_preview(sql: &str) -> String {
    let single_line: String = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() > 60 {
        let prefix: String = single_line.chars().take(60).collect();
        format!("{prefix}…")
    } else {
        single_line
    }
}

/// Top-of-pane status string. Single-statement scripts show the
/// classic "{n} rows in {ms} ms"; multi-statement scripts show
/// "{ok}/{total} statements · {ms} ms" with a trailing error hint
/// when applicable.
fn summary_label(n_total: usize, n_ok: usize, total_ms: u128, has_error: bool) -> String {
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

/// Mount one StatementOutcome into a parent box (for single-result
/// renders) or as an `AdwViewStack` page (multi-result). Wraps grids
/// in a ScrolledWindow so the result pane stays scroll-bounded.
fn build_outcome_widget(o: &StatementOutcome, idx: usize) -> gtk::Widget {
    match &o.kind {
        StatementOutcomeKind::Rows(result) if !result.rows.is_empty() => {
            let (column_view, _selection, _filter) = build_column_view(
                result,
                &result.columns,
                "",
                None,
                None,
                None,
                None,
                TabGridContext::default(),
            );
            let scrolled = gtk::ScrolledWindow::builder()
                .child(&column_view)
                .hexpand(true)
                .vexpand(true)
                .build();
            scrolled.upcast()
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
        StatementOutcomeKind::Error(msg) => adw::StatusPage::builder()
            .title(crate::tr!("Statement {n} failed").replace("{n}", &(idx + 1).to_string()))
            .description(msg)
            .icon_name("dialog-error-symbolic")
            .vexpand(true)
            .build()
            .upcast(),
        StatementOutcomeKind::NotRun => adw::StatusPage::builder()
            .title(crate::tr!("Statement {n} not run").replace("{n}", &(idx + 1).to_string()))
            .description(crate::tr!("Skipped because an earlier statement failed."))
            .icon_name("emblem-synchronizing-symbolic")
            .vexpand(true)
            .build()
            .upcast(),
    }
}

fn outcome_tab_label(idx: usize, o: &StatementOutcome) -> String {
    match &o.kind {
        StatementOutcomeKind::Rows(qr) => {
            let n_str = qr.rows.len().to_string();
            crate::tr!("Result {n} ({rows})")
                .replace("{n}", &(idx + 1).to_string())
                .replace("{rows}", &n_str)
        }
        StatementOutcomeKind::Error(_) => crate::tr!("Result {n} (error)").replace("{n}", &(idx + 1).to_string()),
        StatementOutcomeKind::NotRun => crate::tr!("Result {n} (skipped)").replace("{n}", &(idx + 1).to_string()),
    }
}

fn render_outcomes(holder: &gtk::Box, outcomes: &[StatementOutcome]) {
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
        let widget = build_outcome_widget(&outcomes[0], 0);
        holder.append(&widget);
        return;
    }
    // Multi-statement: nested AdwViewStack with a centred pill
    // ViewSwitcher above. Mirrors the M-1 Table tab pattern (Data ↔
    // Structure) so the visual vocabulary stays consistent across the
    // app — same widget for "different views of the same execution".
    let stack = adw::ViewStack::new();
    for (idx, o) in outcomes.iter().enumerate() {
        let widget = build_outcome_widget(o, idx);
        let icon = match &o.kind {
            StatementOutcomeKind::Rows(_) => "view-grid-symbolic",
            StatementOutcomeKind::Error(_) => "dialog-error-symbolic",
            StatementOutcomeKind::NotRun => "emblem-synchronizing-symbolic",
        };
        let page = stack.add_titled_with_icon(&widget, Some(&format!("r{idx}")), &outcome_tab_label(idx, o), icon);
        if !o.sql_preview.is_empty() {
            // Tooltip on the page widget itself surfaces the SQL
            // preview when hovering the switcher pill.
            widget.set_tooltip_text(Some(&o.sql_preview));
            let _ = page;
        }
    }
    let switcher = adw::ViewSwitcher::builder()
        .stack(&stack)
        .policy(adw::ViewSwitcherPolicy::Wide)
        .build();
    let switcher_holder = gtk::CenterBox::builder()
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    switcher_holder.set_center_widget(Some(&switcher));
    holder.append(&switcher_holder);
    holder.append(&stack);
    // First page is auto-selected; if the script had any errors,
    // jump straight to the first failing statement so the user sees
    // what broke without manual switching.
    if let Some(err_idx) = outcomes
        .iter()
        .position(|o| matches!(o.kind, StatementOutcomeKind::Error(_)))
    {
        stack.set_visible_child_name(&format!("r{err_idx}"));
    }
}

fn split_sql_statements(sql: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut chars = sql.chars().peekable();
    let mut in_single = false;
    let mut in_double = false;
    let mut in_line_comment = false;
    let mut in_block_comment = false;
    while let Some(c) = chars.next() {
        if in_line_comment {
            current.push(c);
            if c == '\n' {
                in_line_comment = false;
            }
            continue;
        }
        if in_block_comment {
            current.push(c);
            if c == '*' && chars.peek() == Some(&'/') {
                current.push(chars.next().unwrap());
                in_block_comment = false;
            }
            continue;
        }
        if !in_single && !in_double {
            if c == '-' && chars.peek() == Some(&'-') {
                current.push(c);
                current.push(chars.next().unwrap());
                in_line_comment = true;
                continue;
            }
            if c == '/' && chars.peek() == Some(&'*') {
                current.push(c);
                current.push(chars.next().unwrap());
                in_block_comment = true;
                continue;
            }
        }
        match c {
            '\'' if !in_double => in_single = !in_single,
            '"' if !in_single => in_double = !in_double,
            ';' if !in_single && !in_double => {
                let trimmed = current.trim().to_string();
                if !trimmed.is_empty() {
                    out.push(trimmed);
                }
                current.clear();
                continue;
            }
            _ => {}
        }
        current.push(c);
    }
    let trimmed = current.trim().to_string();
    if !trimmed.is_empty() {
        out.push(trimmed);
    }
    out
}

pub const SQL_KEYWORDS: &str = "\
SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE \
JOIN INNER LEFT RIGHT FULL OUTER ON USING UNION INTERSECT EXCEPT \
GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT ALL AS WITH \
CREATE TABLE INDEX VIEW DROP ALTER TRUNCATE \
PRIMARY KEY FOREIGN REFERENCES UNIQUE NOT NULL DEFAULT CHECK \
AND OR IS LIKE IN BETWEEN EXISTS ANY \
COUNT SUM AVG MIN MAX CASE WHEN THEN ELSE END \
TRUE FALSE ASC DESC RETURNING";

pub fn build_schema_buffer() -> gtk::TextBuffer {
    let buf = gtk::TextBuffer::new(None);
    buf.set_text(SQL_KEYWORDS);
    buf
}

pub fn update_schema_buffer(buffer: &gtk::TextBuffer, schema_words: &[String]) {
    let mut text = String::from(SQL_KEYWORDS);
    for w in schema_words {
        text.push(' ');
        text.push_str(w);
    }
    buffer.set_text(&text);
}

pub fn derive_tab_label(query: &str) -> String {
    for line in query.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with("--") {
            continue;
        }
        let cleaned: String = trimmed.chars().take(30).collect();
        if cleaned.chars().count() < trimmed.chars().count() {
            return format!("{cleaned}…");
        }
        return cleaned;
    }
    crate::tr!("Empty query")
}

fn apply_editor_scheme(view: &sourceview5::View) {
    let scheme_name = if adw::StyleManager::default().is_dark() {
        "Adwaita-dark"
    } else {
        "Adwaita"
    };
    if let Some(scheme) = sourceview5::StyleSchemeManager::default().scheme(scheme_name)
        && let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>()
    {
        buffer.set_style_scheme(Some(&scheme));
    }
}

fn apply_editor_font_size(_view: &sourceview5::View, font_size: u32) {
    // GTK 4.10+ removed per-widget CssProvider (gtk::Widget::style_context()
    // is deprecated). The replacement is display-scoped — register the rule
    // on the default display; the textview selector ensures only SourceView
    // / TextView descendants are affected (gtk::Entry doesn't match).
    //
    // Track the live provider in a thread-local so the previous one is
    // removed before the new one is installed. Without this, every
    // editor-tab open (and every preferences change) added a fresh
    // provider that nothing ever cleaned up — a slow CSS-provider leak
    // visible in heavy sessions.
    thread_local! {
        static EDITOR_FONT_PROVIDER: std::cell::RefCell<Option<gtk::CssProvider>> =
            const { std::cell::RefCell::new(None) };
    }
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    EDITOR_FONT_PROVIDER.with(|cell| {
        if let Some(prev) = cell.borrow_mut().take() {
            gtk::style_context_remove_provider_for_display(&display, &prev);
        }
        let css = format!("textview, textview text {{ font-size: {font_size}pt; }}");
        let provider = gtk::CssProvider::new();
        provider.load_from_string(&css);
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        *cell.borrow_mut() = Some(provider);
    });
}

#[cfg(test)]
mod tests {
    use super::{split_sql_statements, sql_preview, summary_label};

    #[test]
    fn splits_on_top_level_semicolons() {
        let s = split_sql_statements("SELECT 1; SELECT 2");
        assert_eq!(s, vec!["SELECT 1".to_string(), "SELECT 2".to_string()]);
    }

    #[test]
    fn ignores_semicolons_in_string_literals() {
        let s = split_sql_statements("INSERT INTO t VALUES ('a;b'); SELECT 1");
        assert_eq!(s.len(), 2);
        assert!(s[0].contains("'a;b'"));
    }

    #[test]
    fn ignores_semicolons_in_double_quotes() {
        let s = split_sql_statements("SELECT \"col;name\" FROM t; SELECT 2");
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn ignores_semicolons_in_line_comment() {
        let s = split_sql_statements("SELECT 1 -- comment ; here\n; SELECT 2");
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn ignores_semicolons_in_block_comment() {
        let s = split_sql_statements("SELECT 1 /* hi ; bye */; SELECT 2");
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn trailing_semicolon_does_not_create_empty_statement() {
        let s = split_sql_statements("SELECT 1;");
        assert_eq!(s, vec!["SELECT 1".to_string()]);
    }

    #[test]
    fn empty_input_returns_empty() {
        assert!(split_sql_statements("").is_empty());
        assert!(split_sql_statements("   \n\t  ").is_empty());
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
