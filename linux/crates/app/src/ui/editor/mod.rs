mod format_plan;
mod significant_tokens;
mod statement_cursor;

use std::time::SystemTime;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::prelude::*;
use relm4::{adw, gtk};
use sourceview5::prelude::*;
use tokio_util::sync::CancellationToken;

use tablepro_core::QueryResult;
use tablepro_storage::query_history::{NewEntry, Outcome};

use super::grid::{GridMsg, TabGridContext, build_column_view};
use crate::services::database_service::{self, ConnectionMetadata};

pub struct SqlEditor {
    settings: std::rc::Rc<tablepro_storage::AppSettings>,
    history: Option<tablepro_storage::QueryHistory>,
    tasks: tablepro_session::runtime::Tasks,
    source_view: sourceview5::View,
    run_button: gtk::Button,
    cancel_button: gtk::Button,
    running_spinner: adw::Spinner,
    results_holder: gtk::Box,
    status: gtk::Label,
    grid_sender: relm4::Sender<GridMsg>,
    cancel_token: Option<CancellationToken>,
    executing_sql: Option<String>,
    executing_metadata: Option<ConnectionMetadata>,
    executing_started_at: Option<SystemTime>,
}

pub struct SqlEditorInit {
    pub schema_buffer: gtk::TextBuffer,
    pub initial_query: Option<String>,
    pub settings: std::rc::Rc<tablepro_storage::AppSettings>,
    pub history: Option<tablepro_storage::QueryHistory>,
    pub tasks: tablepro_session::runtime::Tasks,
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
    /// Ctrl+Shift+F → reformat the buffer in place via sqlformat.
    Format,
    /// Ctrl+Shift+Return → run only the SQL statement under the
    /// cursor. Falls back to a status hint when the cursor is in
    /// whitespace or a leading comment with no statement around it.
    RunAtCursor,
    /// Load a `.sql` file into the buffer, so a migration or a script
    /// kept on disk can be run without pasting it in.
    OpenFile,
    /// The file came back; `None` when it could not be read as text.
    FileLoaded(Option<String>),
    /// Ctrl+/ → toggle SQL line-comment for the selected lines (or
    /// the cursor's line). Standard IDE shortcut.
    ToggleLineComment,
    /// Context-menu actions from a result grid.
    Grid(GridMsg),
}

#[derive(Debug)]
pub enum SqlEditorOutput {
    RunStateChanged(bool),
    QueryChanged(String),
    CopyToClipboard(String),
    ShowToast(String),
    /// "Export Results…" from a result grid's context menu, with the
    /// file-name stem derived from the statement that produced it.
    ExportResults {
        result: QueryResult,
        name: String,
    },
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
                adw::Spinner {
                    set_visible: false,
                    set_size_request: (20, 20),
                },

                #[name = "status"]
                gtk::Label {
                    set_halign: gtk::Align::End,
                    add_css_class: "dim-label",
                },

                // Format had only a shortcut, and opening a file had
                // nowhere to live. One menu gives both a place without
                // crowding the bar that Run sits on.
                gtk::MenuButton {
                    set_icon_name: crate::ui::icons::VIEW_MORE,
                    set_tooltip_text: Some(crate::i18n::gettext("Editor options").as_str()),
                    add_css_class: "flat",
                    set_menu_model: Some(&editor_menu()),
                },

                #[name = "cancel_button"]
                gtk::Button {
                    set_label: &crate::i18n::gettext("Cancel"),
                    set_tooltip_text: Some(crate::i18n::gettext("Cancel running query (Esc)").as_str()),
                    set_visible: false,
                    add_css_class: "flat",
                    connect_clicked => SqlEditorInput::Cancel,
                },

                #[name = "run_button"]
                gtk::Button {
                    set_label: &crate::i18n::gettext("Run"),
                    set_tooltip_text: Some(crate::i18n::gettext("Run query (Ctrl+Return)").as_str()),
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

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let widgets = view_output!();

        let actions = relm4::gtk::gio::SimpleActionGroup::new();
        let open_sender = sender.clone();
        let open = relm4::gtk::gio::ActionEntry::builder("open-file")
            .activate(move |_, _, _| open_sender.input(SqlEditorInput::OpenFile))
            .build();
        let format_sender = sender.clone();
        let format = relm4::gtk::gio::ActionEntry::builder("format")
            .activate(move |_, _, _| format_sender.input(SqlEditorInput::Format))
            .build();
        actions.add_action_entries([open, format]);
        root.insert_action_group("editor", Some(&actions));

        let lang_manager = sourceview5::LanguageManager::default();
        let initial_text = init.initial_query.unwrap_or_else(|| "SELECT 1;".to_string());
        if let Some(lang) = lang_manager.language("sql") {
            let buffer = sourceview5::Buffer::with_language(&lang);
            buffer.set_text(&initial_text);
            widgets.source_view.set_buffer(Some(&buffer));
        } else {
            widgets.source_view.buffer().set_text(&initial_text);
        }
        widgets.source_view.add_css_class("sql-editor");
        widgets.source_view.set_monospace(true);

        let settings = init.settings.clone();
        crate::ui::style_scheme_resolver::apply(&widgets.source_view, &settings.style_scheme());
        let view_for_theme = widgets.source_view.clone();
        let settings_for_theme = settings.clone();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            crate::ui::style_scheme_resolver::apply(&view_for_theme, &settings_for_theme.style_scheme());
        });
        let view_for_scheme = widgets.source_view.clone();
        settings.gio().connect_changed(
            Some(tablepro_storage::settings::keys::STYLE_SCHEME),
            move |settings, key| {
                crate::ui::style_scheme_resolver::apply(&view_for_scheme, &settings.string(key));
            },
        );

        crate::ui::editor_font_provider::apply(&settings);
        let settings_for_font = settings.clone();
        for key in [
            tablepro_storage::settings::keys::USE_SYSTEM_FONT,
            tablepro_storage::settings::keys::CUSTOM_FONT,
        ] {
            let settings_for_key = settings_for_font.clone();
            settings.gio().connect_changed(Some(key), move |_, _| {
                crate::ui::editor_font_provider::apply(&settings_for_key);
            });
        }

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
            .trigger(&gtk::KeyvalTrigger::new(
                gtk::gdk::Key::Return,
                gtk::gdk::ModifierType::CONTROL_MASK,
            ))
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
            .trigger(&gtk::KeyvalTrigger::new(
                gtk::gdk::Key::Escape,
                gtk::gdk::ModifierType::empty(),
            ))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::Cancel);
                    glib::Propagation::Stop
                }
            }))
            .build();
        // Ctrl+Shift+F — reformat the buffer in place. Matches the
        // standard IDE shortcut (DataGrip, IntelliJ, VS Code SQL
        // extensions) so users don't have to relearn it. Lives on the
        // source-view controller so it only fires when the editor has
        // focus; window-scoped Ctrl+F is "Find in results".
        let format_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::KeyvalTrigger::new(
                gtk::gdk::Key::f,
                gtk::gdk::ModifierType::CONTROL_MASK | gtk::gdk::ModifierType::SHIFT_MASK,
            ))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::Format);
                    glib::Propagation::Stop
                }
            }))
            .build();
        // Ctrl+Shift+Return — run only the statement under the
        // cursor. Standard DataGrip / DBeaver behaviour for
        // multi-statement scripts: the user keeps several queries in
        // one buffer, parks the cursor on one, runs just that.
        let run_at_cursor_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::KeyvalTrigger::new(
                gtk::gdk::Key::Return,
                gtk::gdk::ModifierType::CONTROL_MASK | gtk::gdk::ModifierType::SHIFT_MASK,
            ))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::RunAtCursor);
                    glib::Propagation::Stop
                }
            }))
            .build();
        // Ctrl+/ — toggle SQL line-comment for the selected lines.
        // Standard IDE shortcut (VS Code, IntelliJ, Sublime, etc.)
        // so users don't have to relearn it. Walks the selection,
        // commenting all lines if any are uncommented, otherwise
        // uncommenting all. Wrapped in begin/end_user_action so it's
        // a single undo step regardless of how many lines toggle.
        let toggle_comment_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::KeyvalTrigger::new(
                gtk::gdk::Key::slash,
                gtk::gdk::ModifierType::CONTROL_MASK,
            ))
            .action(&gtk::CallbackAction::new({
                let sender = sender.clone();
                move |_, _| {
                    sender.input(SqlEditorInput::ToggleLineComment);
                    glib::Propagation::Stop
                }
            }))
            .build();
        let controller = gtk::ShortcutController::new();
        controller.add_shortcut(run_shortcut);
        controller.add_shortcut(cancel_shortcut);
        controller.add_shortcut(format_shortcut);
        controller.add_shortcut(run_at_cursor_shortcut);
        controller.add_shortcut(toggle_comment_shortcut);
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

        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();
        glib::spawn_future_local(grid_receiver.forward(sender.input_sender().clone(), SqlEditorInput::Grid));

        let model = SqlEditor {
            settings,
            history: init.history.clone(),
            tasks: init.tasks.clone(),
            source_view: widgets.source_view.clone(),
            run_button: widgets.run_button.clone(),
            cancel_button: widgets.cancel_button.clone(),
            running_spinner: widgets.running_spinner.clone(),
            results_holder: widgets.results_holder.clone(),
            status: widgets.status.clone(),
            grid_sender,
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
                    self.status.set_label(&crate::i18n::gettext("empty query"));
                    return;
                }
                self.execute_sql(trimmed, sender);
            }

            SqlEditorInput::ToggleLineComment => {
                toggle_line_comment(&self.source_view.buffer());
            }

            SqlEditorInput::Grid(GridMsg::CopyToClipboard(text)) => {
                let _ = sender.output(SqlEditorOutput::CopyToClipboard(text));
            }
            SqlEditorInput::Grid(GridMsg::ShowToast(text)) => {
                let _ = sender.output(SqlEditorOutput::ShowToast(text));
            }
            SqlEditorInput::Grid(GridMsg::ExportResults(result)) => {
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let name = export_name_for_query(&buffer.text(&start, &end, false));
                let _ = sender.output(SqlEditorOutput::ExportResults { result, name });
            }
            SqlEditorInput::Grid(_) => {}

            SqlEditorInput::RunAtCursor => {
                // The user keeps several queries in one buffer and
                // parks the cursor on one to run just that. The script
                // plan decides where that statement starts and ends,
                // so a dollar-quoted body or a `GO` batch is one
                // statement rather than several.
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, false).to_string();
                let grammar = self.grammar();
                let plan = statement_cursor::plan_for(&sql, grammar);
                let cursor_char = buffer.iter_at_mark(&buffer.get_insert()).offset().max(0) as usize;
                let statement = statement_cursor::statement_bounds_at(&buffer, &plan, &sql, cursor_char)
                    .map(|(from, to)| (buffer.text(&from, &to, false).to_string(), from, to))
                    .filter(|(text, _, _)| !text.trim().is_empty());
                let Some((text, from, to)) = statement else {
                    self.status.set_label(&crate::i18n::gettext("No statement at cursor"));
                    return;
                };
                // Selecting it says which of the queries in the buffer
                // is the one that ran.
                buffer.select_range(&from, &to);
                self.execute_sql(text.trim().to_owned(), sender);
            }

            SqlEditorInput::OpenFile => {
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let occupied = !buffer.text(&start, &end, false).trim().is_empty();
                if occupied {
                    // Loading replaces what is in the tab, and the tab
                    // is where the user's unrun work lives.
                    let dialog = adw::AlertDialog::new(
                        Some(&crate::i18n::gettext("Replace the editor contents?")),
                        Some(&crate::i18n::gettext(
                            "The file is loaded into this tab, and what is written here now is replaced.",
                        )),
                    );
                    dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
                    dialog.add_response("replace", &crate::i18n::gettext("Replace"));
                    dialog.set_default_response(Some("cancel"));
                    dialog.set_close_response("cancel");
                    let ask_sender = sender.clone();
                    dialog.connect_response(None, move |dialog, response| {
                        dialog.close();
                        if response == "replace" {
                            choose_sql_file(&ask_sender);
                        }
                    });
                    dialog.present(Some(&self.source_view));
                } else {
                    choose_sql_file(&sender);
                }
            }

            SqlEditorInput::FileLoaded(text) => match text {
                Some(text) => {
                    self.source_view.buffer().set_text(&text);
                    self.status.set_label(&crate::i18n::gettext("File loaded"));
                }
                None => self
                    .status
                    .set_label(&crate::i18n::gettext("The file could not be read as text")),
            },

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
                render_outcomes(&self.results_holder, &outcomes, &self.grid_sender);
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
                self.status.set_label(&crate::i18n::gettext("cancelled"));
                clear_box(&self.results_holder);
                let cancelled_page = adw::StatusPage::builder()
                    .title(crate::i18n::gettext("Query cancelled"))
                    .description(crate::i18n::gettext("The running query was stopped."))
                    .icon_name(crate::ui::icons::PROCESS_STOP)
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
                let reason = crate::i18n::gettext_f(
                    "Query exceeded the {n}s timeout configured in Preferences.",
                    &[("n", &secs_str)],
                );
                self.record_history(elapsed, None, Outcome::Error(reason.clone()));
                self.status.set_label(&crate::i18n::gettext("timed out"));
                clear_box(&self.results_holder);
                let page = adw::StatusPage::builder()
                    .title(crate::i18n::gettext("Query timed out"))
                    .description(&reason)
                    .icon_name(crate::ui::icons::DIALOG_WARNING)
                    .vexpand(true)
                    .build();
                self.results_holder.append(&page);
            }

            SqlEditorInput::ReplaceQuery(text) => {
                self.source_view.buffer().set_text(&text);
            }

            SqlEditorInput::Format => {
                // Formatting runs per statement so anything sqlformat
                // would change the meaning of stays as the user typed
                // it, and so the lines between statements survive.
                // Empty buffers no-op: the formatter returns the same
                // empty string but `set_text` would still bump the
                // change marker.
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let text = buffer.text(&start, &end, false).to_string();
                if text.trim().is_empty() {
                    return;
                }
                let grammar = database_service::instance()
                    .active_metadata()
                    .map(|metadata| tablepro_core::dialect::grammar_for(&metadata.driver_id))
                    .unwrap_or(tablepro_core::sql_syntax::SqlGrammar::PostgreSql);
                let settings = tablepro_core::sql_syntax::script::LexicalSettings::default_for(grammar);
                let formatted = format_plan::format_script(&text, grammar, settings);
                if formatted == text {
                    return;
                }
                // The cursor lands at the start because every byte
                // offset before it has moved; Ctrl+Z puts the old text
                // back.
                buffer.set_text(&formatted);
            }
        }
    }
}

impl SqlEditor {
    /// The SQL grammar of the connection the editor is pointed at,
    /// which decides where statements begin and end.
    fn grammar(&self) -> tablepro_core::sql_syntax::SqlGrammar {
        database_service::instance()
            .active_metadata()
            .map(|metadata| tablepro_core::dialect::grammar_for(&metadata.driver_id))
            .unwrap_or(tablepro_core::sql_syntax::SqlGrammar::PostgreSql)
    }

    /// The text buffer, so the draft writer can read the script once
    /// per write rather than carrying a copy of it per keystroke.
    pub fn buffer(&self) -> gtk::TextBuffer {
        self.source_view.buffer()
    }

    /// Dispatch a pre-trimmed non-empty SQL string into the run path.
    /// Both `Run` (whole buffer) and `RunAtCursor` (single statement
    /// under cursor) funnel through here so the UI-state setup
    /// (cancel token, spinner, status, history-recording context)
    /// stays in one place and can't drift between the two callers.
    fn execute_sql(&mut self, trimmed: String, sender: ComponentSender<Self>) {
        let conn = match database_service::instance().active() {
            Some(c) => c,
            None => {
                self.status.set_label(&crate::i18n::gettext("no active connection"));
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
        self.status.set_label(&crate::i18n::gettext("Running…"));
        clear_box(&self.results_holder);
        let _ = sender.output(SqlEditorOutput::RunStateChanged(true));

        self.executing_sql = Some(trimmed.clone());
        self.executing_metadata = database_service::instance().active_metadata();
        self.executing_started_at = Some(SystemTime::now());

        let statements = statement_cursor::script_statements(&trimmed, self.grammar());
        let timeout = self.settings.query_timeout();
        let timeout_secs = timeout.map_or(0, |duration| duration.as_secs() as u32);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            let statements = statements.clone();
            shutdown
                .register(async move {
                    // A `query_timeout_secs == 0` user opt-out turns
                    // the timeout branch off by holding a future that
                    // never resolves. Otherwise the tokio sleep races
                    // against `cancelled()` and `run_statements()`;
                    // first to finish wins.
                    let timeout: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> = match timeout {
                        Some(duration) => Box::pin(tokio::time::sleep(duration)),
                        None => Box::pin(std::future::pending::<()>()),
                    };
                    // The cancel token is the editor's own signal
                    // channel — the driver does not subscribe to it
                    // (sqlx has no future-drop cancellation hook for
                    // Postgres / MySQL). When the timeout wins, we
                    // *also* fire `token.cancel()` so any outer logic
                    // (pool shutdown, connection monitor) sees the
                    // same "abandoned" signal as a manual Cancel,
                    // and the future drops on the next poll.
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
        let Some(history) = self.history.clone() else {
            return;
        };
        self.tasks.spawn_task(async move {
            if let Err(error) = history.record(entry).await {
                tracing::warn!(%error, "history record failed");
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
            crate::i18n::gettext_f("error in {ms} ms", &[("ms", &ms)])
        } else {
            crate::i18n::gettext_f("done in {ms} ms", &[("ms", &ms)])
        }
    } else {
        let ok_s = n_ok.to_string();
        let total_s = n_total.to_string();
        let ms = total_ms.to_string();
        let base = crate::i18n::gettext_f(
            "{ok}/{total} statements · {ms} ms",
            &[("ok", &ok_s), ("total", &total_s), ("ms", &ms)],
        );
        if has_error {
            format!("{base} · {}", crate::i18n::gettext("error"))
        } else {
            base
        }
    }
}

/// Mount one StatementOutcome into a parent box (for single-result
/// renders) or as an `AdwViewStack` page (multi-result). Wraps grids
/// in a ScrolledWindow so the result pane stays scroll-bounded.
fn build_outcome_widget(o: &StatementOutcome, idx: usize, grid_sender: &relm4::Sender<GridMsg>) -> gtk::Widget {
    match &o.kind {
        StatementOutcomeKind::Rows(result) if !result.rows.is_empty() => {
            let (column_view, _selection) = build_column_view(
                result,
                &[],
                grid_sender.clone(),
                false,
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
                .title(crate::i18n::gettext_f(
                    "Statement {n} executed",
                    &[("n", &(idx + 1).to_string())],
                ))
                .description(crate::i18n::gettext_f("No rows returned · {ms} ms", &[("ms", &ms)]))
                .icon_name(crate::ui::icons::SUCCESS)
                .vexpand(true)
                .build()
                .upcast()
        }
        StatementOutcomeKind::Error(msg) => adw::StatusPage::builder()
            .title(crate::i18n::gettext_f(
                "Statement {n} failed",
                &[("n", &(idx + 1).to_string())],
            ))
            .description(msg)
            .icon_name(crate::ui::icons::DIALOG_ERROR)
            .vexpand(true)
            .build()
            .upcast(),
        StatementOutcomeKind::NotRun => adw::StatusPage::builder()
            .title(crate::i18n::gettext_f(
                "Statement {n} not run",
                &[("n", &(idx + 1).to_string())],
            ))
            .description(crate::i18n::gettext("Skipped because an earlier statement failed."))
            .icon_name(crate::ui::icons::MEDIA_PLAYBACK_STOP)
            .vexpand(true)
            .build()
            .upcast(),
    }
}

fn outcome_tab_label(idx: usize, o: &StatementOutcome) -> String {
    match &o.kind {
        StatementOutcomeKind::Rows(qr) => {
            let n_str = qr.rows.len().to_string();
            crate::i18n::gettext_f(
                "Result {n} ({rows})",
                &[("n", &(idx + 1).to_string()), ("rows", &n_str)],
            )
        }
        StatementOutcomeKind::Error(_) => {
            crate::i18n::gettext_f("Result {n} (error)", &[("n", &(idx + 1).to_string())])
        }
        StatementOutcomeKind::NotRun => {
            crate::i18n::gettext_f("Result {n} (skipped)", &[("n", &(idx + 1).to_string())])
        }
    }
}

fn render_outcomes(holder: &gtk::Box, outcomes: &[StatementOutcome], grid_sender: &relm4::Sender<GridMsg>) {
    if outcomes.is_empty() {
        let placeholder = adw::StatusPage::builder()
            .title(crate::i18n::gettext("Empty query"))
            .description(crate::i18n::gettext("Type a SQL statement and press Run."))
            .icon_name(crate::ui::icons::TEXT_X_GENERIC)
            .vexpand(true)
            .build();
        holder.append(&placeholder);
        return;
    }
    if outcomes.len() == 1 {
        let widget = build_outcome_widget(&outcomes[0], 0, grid_sender);
        holder.append(&widget);
        return;
    }
    // Multi-statement: nested AdwViewStack with a centred pill
    // ViewSwitcher above. Mirrors the M-1 Table tab pattern (Data ↔
    // Structure) so the visual vocabulary stays consistent across the
    // app — same widget for "different views of the same execution".
    let stack = adw::ViewStack::new();
    for (idx, o) in outcomes.iter().enumerate() {
        let widget = build_outcome_widget(o, idx, grid_sender);
        let icon = match &o.kind {
            StatementOutcomeKind::Rows(_) => crate::ui::icons::VIEW_GRID,
            StatementOutcomeKind::Error(_) => crate::ui::icons::DIALOG_ERROR,
            StatementOutcomeKind::NotRun => crate::ui::icons::STATEMENT_PENDING,
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

/// Toggle SQL line-comment (`-- `) for the lines in the buffer's
/// current selection (or the cursor's line when nothing is selected).
/// If every non-blank line in the range is already commented, strip
/// the prefix; otherwise prepend `-- ` after each line's leading
/// whitespace. Blank lines are skipped in both directions so the
/// transform is reversible — toggling twice returns the original
/// text. The whole edit is wrapped in begin/end_user_action so a
/// single Ctrl+Z reverts it regardless of line count.
fn toggle_line_comment(buffer: &gtk::TextBuffer) {
    let (sel_start, sel_end) = buffer.selection_bounds().unwrap_or_else(|| {
        let i = buffer.iter_at_mark(&buffer.get_insert());
        (i, i)
    });
    let start_line = sel_start.line();
    let mut end_line = sel_end.line();
    // Selection that ends at column 0 of the next line shouldn't
    // include that empty trailing row — matches the behaviour of
    // VS Code / Sublime where dragging-and-releasing at the line
    // start doesn't comment the line you released on.
    if sel_end.line_offset() == 0 && end_line > start_line {
        end_line -= 1;
    }

    let lines: Vec<String> = (start_line..=end_line)
        .map(|l| {
            let Some(s) = buffer.iter_at_line(l) else {
                return String::new();
            };
            let mut e = s;
            e.forward_to_line_end();
            buffer.text(&s, &e, false).to_string()
        })
        .collect();

    // Comment vs uncomment decision: if every non-blank line is
    // already commented, this is an uncomment toggle; otherwise
    // it's a comment toggle. Mixed selections (some commented, some
    // not) all become commented — matches IDE convention.
    let all_commented = lines
        .iter()
        .filter(|l| !l.trim().is_empty())
        .all(|l| l.trim_start().starts_with("--"));

    buffer.begin_user_action();
    for (offset, original) in lines.iter().enumerate() {
        if original.trim().is_empty() {
            continue;
        }
        let line_n = start_line + offset as i32;
        let leading_chars: i32 = original.chars().take_while(|c| c.is_whitespace()).count() as i32;
        let Some(mut iter) = buffer.iter_at_line(line_n) else {
            continue;
        };
        iter.forward_chars(leading_chars);

        if all_commented {
            // Strip "-- " or "--" depending on what's there. The
            // space is part of the canonical form we insert, so
            // peel it off too when present.
            let trimmed = original.trim_start();
            let strip_chars: i32 = if trimmed.starts_with("-- ") {
                3
            } else if trimmed.starts_with("--") {
                2
            } else {
                0
            };
            if strip_chars > 0 {
                let mut end = iter;
                end.forward_chars(strip_chars);
                buffer.delete(&mut iter, &mut end);
            }
        } else {
            buffer.insert(&mut iter, "-- ");
        }
    }
    buffer.end_user_action();
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

/// File-name stem for an editor export, taken from the statement that
/// produced the results: exporting two queries in a row proposes two
/// different files instead of offering to overwrite the first.
pub fn export_name_for_query(query: &str) -> String {
    if query.trim().is_empty() {
        return crate::i18n::gettext("query-results");
    }
    let mut stem = String::new();
    for c in derive_tab_label(query).chars() {
        if c.is_alphanumeric() {
            stem.extend(c.to_lowercase());
        } else if !stem.ends_with('-') {
            stem.push('-');
        }
    }
    match stem.trim_matches('-') {
        "" => crate::i18n::gettext("query-results"),
        trimmed => trimmed.to_string(),
    }
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
    crate::i18n::gettext("Empty query")
}

/// The editor's own menu.
fn editor_menu() -> relm4::gtk::gio::Menu {
    let menu = relm4::gtk::gio::Menu::new();
    menu.append(Some(&crate::i18n::gettext("Open SQL File…")), Some("editor.open-file"));
    menu.append(Some(&crate::i18n::gettext("Format")), Some("editor.format"));
    menu
}

/// The most a file may be before the editor refuses it.
///
/// A dump can be gigabytes, and a text buffer holding one stops being
/// an editor. Refusing is better than a window that will not paint.
const MAX_SQL_FILE_BYTES: u64 = 8 * 1024 * 1024;

/// Ask for a `.sql` file and read it off the main thread.
fn choose_sql_file(sender: &ComponentSender<SqlEditor>) {
    use relm4::gtk::gio;

    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::i18n::gettext("SQL files")));
    filter.add_suffix("sql");
    filter.add_mime_type("application/sql");
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let dialog = gtk::FileDialog::builder()
        .title(crate::i18n::gettext("Open SQL File"))
        .modal(true)
        .default_filter(&filter)
        .filters(&filters)
        .build();

    let sender = sender.clone();
    dialog.open(gtk::Window::NONE, gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else { return };
        let too_big = file
            .query_info("standard::size", gio::FileQueryInfoFlags::NONE, gio::Cancellable::NONE)
            .map(|info| info.size() as u64 > MAX_SQL_FILE_BYTES)
            .unwrap_or(false);
        if too_big {
            sender.input(SqlEditorInput::FileLoaded(None));
            return;
        }
        let sender = sender.clone();
        glib::spawn_future_local(async move {
            // gio reads off the main thread and hands the bytes back
            // on it, so a file on a slow disk does not freeze the UI.
            let loaded = file.load_contents_future().await;
            let text = loaded
                .ok()
                .and_then(|(bytes, _)| String::from_utf8(bytes.to_vec()).ok());
            sender.input(SqlEditorInput::FileLoaded(text));
        });
    });
}

#[cfg(test)]
mod tests {
    use super::{export_name_for_query, sql_preview, summary_label};

    #[test]
    fn export_name_slugs_the_statement() {
        assert_eq!(export_name_for_query("SELECT * FROM users"), "select-from-users");
        assert_eq!(export_name_for_query("  select id\nfrom t"), "select-id");
    }

    #[test]
    fn export_name_falls_back_when_there_is_no_statement() {
        assert_eq!(export_name_for_query("   \n  "), crate::i18n::gettext("query-results"));
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
