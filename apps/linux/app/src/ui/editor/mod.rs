use tablepro_app_services::{completion, completion_identifiers, completion_proposals};
mod completion_provider;
mod diagnostics;
mod error_location;
mod find_bar;
mod finish_notice;
mod folding;
pub(crate) mod open_file;
mod query_changes;
mod run_lifecycle;
mod session_lexing;
use run_lifecycle::{clear_results_box, dim_previous_results};
use tablepro_core::sql_format as format_plan;
mod outcomes;
mod pinned;
mod run_generation;
mod run_marks;
mod schema;
mod session_mode;
mod split_view;
mod sql_text;
mod statement_band;
mod statement_cursor;
mod stream_functions;
mod stream_pages;
mod stream_view;
mod streaming;
mod timeout_retry;

use std::time::SystemTime;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::prelude::*;
use relm4::{adw, gtk};
use sourceview5::prelude::*;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use stream_pages::{StreamTerminal, StreamedResult};
use streaming::ActiveStream;
use tablepro_core::QueryResult;
use tablepro_storage::query_history::{HistoryStore, NewEntry, Outcome};

use crate::services::database_service::ConnectionMetadata;
use crate::ui::grid::GridMsg;

pub use completion::{SchemaIndex, SchemaRequest};
pub(crate) use completion_identifiers::{catalog_reference, split_table_reference, table_key};
pub use schema::derive_tab_label;
pub(crate) use session_mode::{StreamSession, query_cursor_export_factory};
pub use statement_cursor::grammar_for;

use outcomes::{ScriptRunResult, StatementRun, StreamUpdate, clear_box, render_outcomes, run_statements_with_stream};
use run_generation::{RunGeneration, RunTerminal};
use schema::{apply_editor_preferences, apply_editor_scheme};
use sql_text::{export_name_for_query, read_sql_text, toggle_line_comment};
use statement_cursor::{
    PlannedStatements, adjacent_statement_start, cursor_byte_offset, script_statements, statement_at_cursor,
};

fn show_cancel_button(running: bool, supports_server_cancellation: bool) -> bool {
    running && supports_server_cancellation
}

pub struct SqlEditor {
    catalog_changes: crate::services::catalog::CatalogChanges,
    catalog_origin: Option<crate::services::catalog::CatalogOrigin>,
    diagnostics: diagnostics::Diagnostics,
    source_view: sourceview5::View,
    split_view: split_view::SplitEditorView,
    find: Option<find_bar::FindBar>,
    run_button: gtk::Button,
    folding: std::rc::Rc<std::cell::RefCell<folding::FoldController>>,
    session_button: gtk::ToggleButton,
    session: Option<session_mode::EditorSession>,
    retired_session_connection_id: Option<(Uuid, Uuid)>,
    opening_session_id: Option<Uuid>,
    session_open_in_flight: bool,
    ending_session_id: Option<Uuid>,
    session_teardown_active: bool,
    session_teardown_running: bool,
    session_teardown_waiters: Vec<tokio::sync::oneshot::Sender<Result<(), String>>>,
    cancel_button: gtk::Button,
    longer_timeout_button: gtk::Button,
    timeout_retry: timeout_retry::TimeoutRetry,
    pin_button: gtk::Button,
    pinned: pinned::PinnedResults,
    result_view_settings: crate::ui::grid::local_filter::LocalResultSettingsStore,
    running_spinner: gtk::Spinner,
    results_holder: gtk::Box,
    status: gtk::Label,
    grid_sender: relm4::Sender<GridMsg>,
    cancel_token: Option<CancellationToken>,
    executions: std::collections::HashMap<u64, ExecutionContext>,
    streaming: Option<ActiveStream>,
    connection_id: Option<Uuid>,
    history: Option<HistoryStore>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    preferences: crate::services::preferences::PreferencesStore,
    run_generation: RunGeneration,
    drop_generation: std::rc::Rc<DropGeneration>,
    known_lexing: session_lexing::KnownLexing,
    reading_lexing: bool,
    /// Disconnected in `shutdown`. Without this, every tab's
    /// `connect_dark_notify` closure -- which strongly captures this
    /// tab's `source_view` -- stayed registered on the process-global
    /// `AdwStyleManager` forever, keeping the whole tab's widget tree
    /// alive past the tab's own close.
    dark_notify_handler: Option<glib::SignalHandlerId>,
}

pub struct SqlEditorInit {
    pub schema_index: std::rc::Rc<std::cell::RefCell<SchemaIndex>>,
    pub initial_query: Option<String>,
    pub connection_id: Option<Uuid>,
    pub history: Option<HistoryStore>,
    pub database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    pub preferences: crate::services::preferences::PreferencesStore,
}

#[derive(Debug, Clone)]
pub struct StatementOutcome {
    pub identity: StatementIdentity,
    pub sql_preview: String,
    pub elapsed_ms: u128,
    pub kind: StatementOutcomeKind,
    pub pinned: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub struct StatementIdentity {
    pub statement_index: usize,
    pub digest: [u8; 32],
}

#[derive(Debug, Clone)]
pub enum StatementOutcomeKind {
    Rows(Vec<std::sync::Arc<QueryResult>>),
    Streamed(Box<StreamedResult>),
    Error(String),
    NotRun,
}

#[derive(Debug)]
pub enum SqlEditorInput {
    CatalogStatementSucceeded {
        origin: crate::services::catalog::CatalogOrigin,
        driver: String,
        sql: String,
    },
    Run,
    RunWithParameters {
        sql: String,
        planned: PlannedStatements,
        values: std::collections::HashMap<String, tablepro_core::Value>,
    },
    LexingRead {
        source: session_lexing::LexingSource,
        sql: String,
        result: Result<Option<tablepro_core::sql_syntax::script::LexicalSettings>, String>,
    },
    LexingRefreshed {
        source: session_lexing::LexingSource,
        settings: Option<tablepro_core::sql_syntax::script::LexicalSettings>,
    },
    Cancel,
    TogglePin,
    SplitToggled(bool),
    ShowOutcomes {
        generation: u64,
        outcomes: Vec<StatementOutcome>,
    },
    StreamStarted {
        generation: u64,
        identity: StatementIdentity,
        sql_preview: String,
        export_query: Option<crate::ui::export_dialog::StreamExportQuery>,
        accepted: tokio::sync::oneshot::Sender<bool>,
    },
    StreamPage {
        generation: u64,
        sequence: u64,
        page: std::sync::Arc<QueryResult>,
        accepted: tokio::sync::oneshot::Sender<bool>,
    },
    StreamFinished {
        generation: u64,
        terminal: StreamTerminal,
    },
    RunWithLongerTimeout,
    ShowCancelled(u64),
    ShowTimedOut {
        generation: u64,
        secs: u32,
    },
    InsertDroppedSql {
        request: DropRequest,
        text: String,
    },
    DroppedSqlFailed {
        request: DropRequest,
        message: String,
    },
    ReplaceQuery(String),
    Format,
    RunAtCursor,
    JumpStatement {
        forward: bool,
    },
    ToggleLineComment,
    ToggleFold,
    UnfoldAll,
    ShowFind,
    Explain,
    Grid(GridMsg),
    SessionToggled(bool),
    SessionOpened {
        connection_id: Uuid,
        connection_identity: crate::services::database_service::ConnectionIdentity,
        session_id: Uuid,
        result: Result<session_mode::OpenedSession, String>,
    },
    ConnectionIdentityChanged,
    SessionState {
        session_id: Uuid,
        transaction_open: bool,
        usable: bool,
    },
    SessionEnd {
        session_id: Uuid,
        commit: bool,
    },
    SessionCommitFinished {
        session_id: Uuid,
        result: Result<tablepro_core::SessionCommitOutcome, String>,
    },
    SessionRollbackFinished {
        session_id: Uuid,
        result: Result<(), String>,
    },
    PrepareForTeardown(tokio::sync::oneshot::Sender<Result<(), String>>),
    SessionTeardownFinished(Result<(), String>),
}

#[derive(Debug)]
pub enum SqlEditorOutput {
    CatalogChanged(crate::services::catalog::CatalogOrigin),
    RunStateChanged(bool),
    QueryChanged(String),
    NeedColumns(Vec<String>),
    CopyToClipboard(String),
    ShowRowAsJson(String),
    ExportResults { result: QueryResult, name: String },
    ExportStreamedResults(crate::ui::export_dialog::StreamExportRequest),
}

pub(super) const MAX_SQL_FILE_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug)]
struct ExecutionContext {
    sql: String,
    lexical: Option<tablepro_core::sql_syntax::script::LexicalSettings>,
    metadata: ConnectionMetadata,
    started_at: SystemTime,
    timeout_secs: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct DropRequest {
    generation: u64,
    revision: u64,
}

#[derive(Debug, Default)]
struct DropGeneration {
    generation: std::cell::Cell<u64>,
    revision: std::cell::Cell<u64>,
}

impl DropGeneration {
    fn changed(&self) {
        self.revision.set(self.revision.get().wrapping_add(1));
    }

    fn begin(&self) -> DropRequest {
        let generation = self.generation.get().wrapping_add(1);
        self.generation.set(generation);
        DropRequest {
            generation,
            revision: self.revision.get(),
        }
    }

    fn accepts(&self, request: DropRequest) -> bool {
        self.generation.get() == request.generation && self.revision.get() == request.revision
    }
}

#[relm4::component(pub)]
impl SimpleComponent for SqlEditor {
    type Init = SqlEditorInit;
    type Input = SqlEditorInput;
    type Output = SqlEditorOutput;

    view! {
        #[root]
        adw::BreakpointBin {
            set_width_request: 600,
            set_height_request: 240,

            #[wrap(Some)]
            #[name = "toolbar_view"]
            set_child = &adw::ToolbarView {
                add_top_bar = &gtk::Box {
                    set_orientation: gtk::Orientation::Horizontal,
                    set_spacing: 8,
                    set_margin_top: 8,
                    set_margin_bottom: 8,
                    set_margin_start: 8,
                    set_margin_end: 8,
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

                    #[name = "session_button"]
                    gtk::ToggleButton {
                        set_label: &crate::tr!("Session"),
                        set_tooltip_text: Some(crate::tr!("Run this tab on its own connection, so settings, temporary tables and transactions carry over between runs").as_str()),
                        add_css_class: "flat",
                        connect_toggled[sender] => move |button| {
                            sender.input(SqlEditorInput::SessionToggled(button.is_active()));
                        },
                    },

                    #[name = "run_button"]
                    gtk::Button {
                        set_label: &crate::tr!("Run"),
                        set_tooltip_text: Some(crate::tr!("Run query (Ctrl+Return)").as_str()),
                        add_css_class: "suggested-action",
                        connect_clicked => SqlEditorInput::Run,
                    },
                },

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
                    #[name = "fold_button"]
                    gtk::Button {
                        set_label: &crate::tr!("Fold block"),
                        set_tooltip_text: Some(crate::tr!("Fold the SQL block at the cursor").as_str()),
                        add_css_class: "flat",
                        connect_clicked => SqlEditorInput::ToggleFold,
                    },

                    #[name = "unfold_button"]
                    gtk::Button {
                        set_label: &crate::tr!("Unfold all"),
                        set_tooltip_text: Some(crate::tr!("Show all folded SQL blocks").as_str()),
                        add_css_class: "flat",
                        connect_clicked => SqlEditorInput::UnfoldAll,
                    },

                    #[name = "warnings_button"]
                    gtk::MenuButton {
                        set_label: &crate::tr!("SQL warnings"),
                        set_tooltip_text: Some(crate::tr!("Character suggestions; SQL is not changed").as_str()),
                        set_visible: false,
                    },

                    #[name = "pin_button"]
                    gtk::Button {
                        set_label: &crate::tr!("Pin results"),
                        set_tooltip_text: Some(crate::tr!("Keep these results above the results of the next run").as_str()),
                        set_sensitive: false,
                        add_css_class: "flat",
                        connect_clicked => SqlEditorInput::TogglePin,
                    },

                    #[name = "explain_button"]
                    gtk::Button {
                        set_label: &crate::tr!("Explain"),
                        set_tooltip_text: Some(crate::tr!("Explain query plan").as_str()),
                        add_css_class: "flat",
                        connect_clicked => SqlEditorInput::Explain,
                    },

                    #[name = "split_button"]
                    gtk::ToggleButton {
                        set_label: &crate::tr!("Split"),
                        set_tooltip_text: Some(crate::tr!("Show or hide a second SQL editor pane").as_str()),
                        add_css_class: "flat",
                        connect_toggled[sender] => move |button| {
                            sender.input(SqlEditorInput::SplitToggled(button.is_active()));
                        },
                    },
                },

                #[name = "longer_timeout_button"]
                add_top_bar = &gtk::Button {
                        set_visible: false,
                        set_halign: gtk::Align::End,
                        set_margin_end: 8,
                        set_margin_bottom: 8,
                        set_tooltip_text: Some(crate::tr!("Runs the same query again. The saved query timeout does not change.").as_str()),
                        add_css_class: "flat",
                        connect_clicked => SqlEditorInput::RunWithLongerTimeout,
                    },

                #[wrap(Some)]
                set_content = &gtk::Paned {
                    set_orientation: gtk::Orientation::Vertical,
                    set_position: 280,
                    set_vexpand: true,
                    set_hexpand: true,

                    #[wrap(Some)]
                    #[name = "editor_holder"]
                    set_start_child = &gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
                        set_vexpand: true,
                        set_hexpand: true,

                        #[name = "source_scroll"]
                        gtk::ScrolledWindow {
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
                    },

                    #[wrap(Some)]
                    #[name = "results_holder"]
                    set_end_child = &gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
                    },
                },
            }
        }
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let widgets = view_output!();

        let lang_manager = sourceview5::LanguageManager::default();
        let initial_text = init.initial_query.unwrap_or_else(|| "SELECT 1;".to_string());
        if let Some(lang) = lang_manager.language("sql") {
            let buffer = sourceview5::Buffer::with_language(&lang);
            buffer.set_text(&initial_text);
            widgets.source_view.set_buffer(Some(&buffer));
        } else {
            let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
            buffer.set_text(&initial_text);
            widgets.source_view.set_buffer(Some(&buffer));
        }
        let split_view =
            split_view::SplitEditorView::install(&widgets.editor_holder, &widgets.source_scroll, &widgets.source_view);
        let known_lexing = session_lexing::KnownLexing::default();
        statement_band::install(
            widgets.source_view.buffer().upcast_ref(),
            init.database.clone(),
            init.connection_id,
            known_lexing.clone(),
        );
        run_marks::install(&widgets.source_view);
        let folding = std::rc::Rc::new(std::cell::RefCell::new(folding::FoldController::new(
            &widgets.source_view.buffer(),
        )));
        folding.borrow().install(&widgets.source_view);
        folding.borrow().install(split_view.secondary_view());
        for view in [&widgets.source_view, split_view.secondary_view()] {
            let folding_for_mark = folding.clone();
            view.connect_line_mark_activated(move |view, iter, button, _, _| {
                if button == 1
                    && let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>()
                {
                    folding_for_mark.borrow_mut().unfold_line(&buffer, iter.line());
                }
            });
        }
        let narrow = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            900.0,
            adw::LengthUnit::Px,
        ));
        narrow.add_setter(&widgets.fold_button, "visible", Some(&false.into()));
        narrow.add_setter(&widgets.unfold_button, "visible", Some(&false.into()));
        root.add_breakpoint(narrow);
        finish_notice::fit_status(&widgets.status);
        let find = find_bar::FindBar::new(&widgets.source_view);
        if let Some(find) = &find {
            widgets.toolbar_view.add_top_bar(find.widget());
        }
        apply_editor_scheme(&widgets.source_view);
        let view_for_theme = widgets.source_view.clone();
        let dark_notify_handler = adw::StyleManager::default().connect_dark_notify(move |_| {
            apply_editor_scheme(&view_for_theme);
        });

        let preferences = init.preferences.load();
        apply_editor_preferences(&widgets.source_view, &preferences);
        apply_editor_preferences(split_view.secondary_view(), &preferences);

        let provider = completion_provider::install(init.schema_index.clone(), known_lexing.clone());
        let completion = widgets.source_view.completion();
        completion.add_provider(&provider);
        split_view.secondary_view().completion().add_provider(&provider);

        let cursor_info = widgets.cursor_info.clone();
        let update_cursor = move |buffer: &gtk::TextBuffer| {
            let mark = buffer.get_insert();
            let iter = buffer.iter_at_mark(&mark);
            let line = iter.line() + 1;
            let col = iter.line_offset() + 1;
            cursor_info.set_label(&format!("Ln {line}, Col {col}"));
        };
        update_cursor(&widgets.source_view.buffer());
        widgets
            .source_view
            .buffer()
            .connect_cursor_position_notify(move |buffer| update_cursor(buffer));

        let refresh_completion = completion_provider::build_completion_refresh(
            widgets.source_view.clone(),
            init.schema_index.clone(),
            known_lexing.clone(),
            sender.clone(),
        );

        refresh_completion();
        let refresh_on_cursor = refresh_completion.clone();
        widgets
            .source_view
            .buffer()
            .connect_cursor_position_notify(move |_| refresh_on_cursor());

        let drop_generation = std::rc::Rc::new(DropGeneration::default());
        query_changes::install(
            &widgets.source_view,
            drop_generation.clone(),
            folding.clone(),
            sender.clone(),
            refresh_completion,
        );
        split_view::install_shortcuts(&widgets.source_view, &sender);
        split_view::install_shortcuts(split_view.secondary_view(), &sender);
        split_view::install_drop_target(&widgets.source_view, &sender, &drop_generation);
        split_view::install_drop_target(split_view.secondary_view(), &sender, &drop_generation);

        let (grid_sender, grid_receiver) = relm4::channel::<GridMsg>();
        let grid_input = sender.input_sender().clone();
        relm4::spawn_local(grid_receiver.forward(grid_input, SqlEditorInput::Grid));

        let model = SqlEditor {
            catalog_changes: Default::default(),
            catalog_origin: None,
            database: init.database.clone(),
            preferences: init.preferences.clone(),
            diagnostics: diagnostics::Diagnostics::install(
                &widgets.source_view,
                &widgets.warnings_button,
                init.connection_id,
                init.database.clone(),
            ),
            source_view: widgets.source_view.clone(),
            split_view,
            folding,
            find,
            run_button: widgets.run_button.clone(),
            session_button: widgets.session_button.clone(),
            session: None,
            retired_session_connection_id: None,
            opening_session_id: None,
            session_open_in_flight: false,
            ending_session_id: None,
            session_teardown_active: false,
            session_teardown_running: false,
            session_teardown_waiters: Vec::new(),
            cancel_button: widgets.cancel_button.clone(),
            longer_timeout_button: widgets.longer_timeout_button.clone(),
            timeout_retry: timeout_retry::TimeoutRetry::default(),
            pin_button: widgets.pin_button.clone(),
            pinned: pinned::PinnedResults::default(),
            result_view_settings: Default::default(),
            running_spinner: widgets.running_spinner.clone(),
            results_holder: widgets.results_holder.clone(),
            status: widgets.status.clone(),
            grid_sender,
            cancel_token: None,
            executions: std::collections::HashMap::new(),
            streaming: None,
            connection_id: init.connection_id,
            history: init.history,
            run_generation: RunGeneration::default(),
            drop_generation,
            known_lexing,
            reading_lexing: false,
            dark_notify_handler: Some(dark_notify_handler),
        };
        ComponentParts { model, widgets }
    }

    fn shutdown(&mut self, _widgets: &mut Self::Widgets, _output: relm4::Sender<Self::Output>) {
        self.diagnostics.stop();
        if let Some(session) = self.session.take() {
            session_mode::close_detached(session.shared);
        }
        if let Some(handler) = self.dark_notify_handler.take() {
            adw::StyleManager::default().disconnect(handler);
        }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            SqlEditorInput::CatalogStatementSucceeded { origin, driver, sql } => {
                if !origin.owns_window(self.connection_id, &self.database) {
                    return;
                }
                if self.catalog_origin.as_ref() != Some(&origin) {
                    self.catalog_changes = Default::default();
                    self.catalog_origin = Some(origin.clone());
                }
                if self.catalog_changes.succeeded(&sql, &driver) {
                    let _ = sender.output(SqlEditorOutput::CatalogChanged(origin));
                }
            }
            SqlEditorInput::Grid(GridMsg::CopyToClipboard(text)) => {
                let _ = sender.output(SqlEditorOutput::CopyToClipboard(text));
            }
            SqlEditorInput::Grid(GridMsg::ShowRowAsJson(text)) => {
                let _ = sender.output(SqlEditorOutput::ShowRowAsJson(text));
            }
            SqlEditorInput::Grid(GridMsg::ExportResults(result)) => {
                let _ = sender.output(SqlEditorOutput::ExportResults {
                    result,
                    name: self.export_name(),
                });
            }
            SqlEditorInput::Grid(GridMsg::ExportStreamedResults(request)) => {
                let _ = sender.output(SqlEditorOutput::ExportStreamedResults(request));
            }
            SqlEditorInput::Grid(_) => {}
            SqlEditorInput::SplitToggled(visible) => self.split_view.set_visible(visible),
            SqlEditorInput::SessionToggled(enabled) => self.on_session_toggled(enabled, &sender),
            SqlEditorInput::SessionOpened {
                connection_id,
                connection_identity,
                session_id,
                result,
            } => self.on_session_opened(connection_id, connection_identity, session_id, result, &sender),
            SqlEditorInput::ConnectionIdentityChanged => {
                self.known_lexing.forget();
                self.on_connection_identity_changed(&sender);
            }
            SqlEditorInput::SessionState {
                session_id,
                transaction_open,
                usable,
            } => self.on_session_state(session_id, transaction_open, usable, &sender),
            SqlEditorInput::SessionEnd { session_id, commit } if commit => {
                self.commit_and_end(session_id, &sender);
            }
            SqlEditorInput::SessionEnd { session_id, .. } => {
                if session_mode::session_callback_matches(session_id, self.session.as_ref().map(|session| session.id)) {
                    self.rollback_and_end(session_id, &sender);
                }
            }
            SqlEditorInput::SessionCommitFinished { session_id, result } => {
                self.on_session_commit_finished(session_id, result, &sender);
            }
            SqlEditorInput::SessionRollbackFinished { session_id, result } => {
                self.on_session_rollback_finished(session_id, result);
            }
            SqlEditorInput::PrepareForTeardown(reply) => self.prepare_for_teardown(reply, &sender),
            SqlEditorInput::SessionTeardownFinished(result) => self.finish_session_teardown(result),
            SqlEditorInput::Run => {
                self.timeout_retry.clear_override();
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, true).to_string();
                let trimmed = sql.trim().to_string();
                if trimmed.is_empty() {
                    self.status.set_label(&crate::tr!("empty query"));
                    return;
                }
                self.begin_run(trimmed, false, sender);
            }

            SqlEditorInput::RunWithParameters { sql, planned, values } => {
                self.execute_sql(sql, planned, values, sender);
            }

            SqlEditorInput::LexingRead { source, sql, result } => self.on_lexing_read(source, sql, result, sender),
            SqlEditorInput::LexingRefreshed { source, settings } => self.on_lexing_refreshed(source, settings),

            SqlEditorInput::ToggleLineComment => {
                toggle_line_comment(&self.source_view.buffer());
            }

            SqlEditorInput::ToggleFold => {
                let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
                let grammar = statement_cursor::grammar_for(&driver_id)
                    .unwrap_or(tablepro_core::sql_syntax::SqlGrammar::PostgreSql);
                let settings = self.lexing(&driver_id).settings_for(grammar);
                if let Ok(buffer) = self.source_view.buffer().downcast::<sourceview5::Buffer>() {
                    self.folding.borrow_mut().toggle_at_cursor(&buffer, grammar, settings);
                }
            }

            SqlEditorInput::UnfoldAll => {
                if let Ok(buffer) = self.source_view.buffer().downcast::<sourceview5::Buffer>() {
                    self.folding.borrow_mut().unfold_all(&buffer);
                }
            }

            SqlEditorInput::Explain => {
                let buffer = self.source_view.buffer();
                let text = if let Some((a, b)) = buffer.selection_bounds() {
                    buffer.text(&a, &b, true).to_string()
                } else {
                    let (start, end) = buffer.bounds();
                    let all = buffer.text(&start, &end, true).to_string();
                    let cursor_chars = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
                    let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
                    let cursor = cursor_byte_offset(&all, cursor_chars);
                    statement_at_cursor(&all, self.lexing(&driver_id), cursor).unwrap_or(all)
                };
                if let Some(window) = self.source_view.root().and_then(|r| r.downcast::<gtk::Window>().ok()) {
                    crate::ui::explain_dialog::present(
                        &window,
                        self.connection_id,
                        &text,
                        &self.database,
                        &self.preferences,
                    );
                }
            }

            SqlEditorInput::JumpStatement { forward } => {
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, true).to_string();
                let cursor_chars = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
                let cursor_byte = cursor_byte_offset(&sql, cursor_chars);
                let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
                let Some(target) = adjacent_statement_start(&sql, self.lexing(&driver_id), cursor_byte, forward) else {
                    return;
                };
                let target_chars = sql[..target].chars().count() as i32;
                buffer.place_cursor(&buffer.iter_at_offset(target_chars));
                self.source_view.scroll_mark_onscreen(&buffer.get_insert());
            }

            SqlEditorInput::RunAtCursor => {
                self.timeout_retry.clear_override();
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, true).to_string();
                let cursor_chars = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
                let cursor_byte = cursor_byte_offset(&sql, cursor_chars);
                let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
                let Some(statement) = statement_at_cursor(&sql, self.lexing(&driver_id), cursor_byte) else {
                    self.status.set_label(&crate::tr!("No statement at cursor"));
                    return;
                };
                self.begin_run(statement, true, sender);
            }

            SqlEditorInput::RunWithLongerTimeout => {
                let Some(sql) = self.timeout_retry.accept() else {
                    return;
                };
                self.longer_timeout_button.set_visible(false);
                self.begin_run(sql, false, sender);
            }

            SqlEditorInput::Cancel => {
                if self.cancel_button.is_visible()
                    && let Some(token) = self.cancel_token.take()
                {
                    token.cancel();
                }
            }

            SqlEditorInput::TogglePin => self.toggle_pin(),

            SqlEditorInput::ShowOutcomes { generation, outcomes } => {
                let Some((terminal, context)) = self.finish_run(generation, &sender) else {
                    return;
                };
                if terminal.replace_ui {
                    self.cancel_token = None;
                }
                let totals = outcomes::RunTotals::of(&outcomes);
                self.mark_statements(&context, terminal.replace_ui, &outcomes);
                self.record_history(
                    context,
                    totals.elapsed_ms as i64,
                    totals.history_rows(),
                    totals.history_outcome(),
                );
                if !terminal.replace_ui {
                    return;
                }

                self.status.set_label(&totals.summary());
                let shown = self.pinned.show(outcomes);
                self.refresh_pin_button();
                clear_results_box(&self.results_holder);
                render_outcomes(
                    &self.results_holder,
                    &shown,
                    &self.grid_sender,
                    self.connection_id,
                    self.database.clone(),
                    self.result_view_settings.clone(),
                );
            }

            SqlEditorInput::StreamStarted {
                generation,
                identity,
                sql_preview,
                export_query,
                accepted,
            } => self.on_stream_started(generation, identity, sql_preview, export_query, accepted),

            SqlEditorInput::StreamPage {
                generation,
                sequence,
                page,
                accepted,
            } => self.on_stream_page(generation, sequence, page, accepted),

            SqlEditorInput::StreamFinished { generation, terminal } => {
                self.on_stream_finished(generation, terminal, &sender);
            }

            SqlEditorInput::ShowCancelled(generation) => {
                let Some((terminal, context)) = self.finish_run(generation, &sender) else {
                    return;
                };
                let elapsed = SystemTime::now()
                    .duration_since(context.started_at)
                    .map(|duration| duration.as_millis() as i64)
                    .unwrap_or(0);
                self.record_history(context, elapsed, None, Outcome::Cancelled);
                if !terminal.replace_ui {
                    return;
                }
                self.cancel_token = None;
                self.status.set_label(&crate::tr!("cancelled"));
                let cancelled_page = adw::StatusPage::builder()
                    .title(crate::tr!("Query cancelled"))
                    .description(crate::tr!("The running query was stopped."))
                    .icon_name("process-stop-symbolic")
                    .vexpand(true)
                    .build();
                self.show_pins_above(&cancelled_page);
            }

            SqlEditorInput::ShowTimedOut { generation, secs } => {
                let Some((terminal, context)) = self.finish_run(generation, &sender) else {
                    return;
                };
                let elapsed = SystemTime::now()
                    .duration_since(context.started_at)
                    .map(|duration| duration.as_millis() as i64)
                    .unwrap_or(0);
                let secs_str = secs.to_string();
                let reason = crate::tr!("Query exceeded the {n}s query timeout.").replace("{n}", &secs_str);
                let timed_out_sql = context.sql.clone();
                self.record_history(context, elapsed, None, Outcome::Error(reason.clone()));
                if !terminal.replace_ui {
                    return;
                }
                self.cancel_token = None;
                self.status.set_label(&crate::tr!("timed out"));
                self.offer_longer_timeout(secs, timed_out_sql);
                let page = adw::StatusPage::builder()
                    .title(crate::tr!("Query timed out"))
                    .description(&reason)
                    .icon_name("dialog-warning-symbolic")
                    .vexpand(true)
                    .build();
                self.show_pins_above(&page);
            }

            SqlEditorInput::InsertDroppedSql { request, text } => {
                if !self.drop_generation.accepts(request) {
                    return;
                }
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                if buffer.text(&start, &end, true).trim().is_empty() {
                    buffer.set_text(&text);
                } else {
                    buffer.insert_at_cursor(&text);
                }
            }

            SqlEditorInput::DroppedSqlFailed { request, message } => {
                if self.drop_generation.accepts(request) {
                    self.status.set_label(&message);
                }
            }

            SqlEditorInput::ReplaceQuery(text) => {
                self.source_view.buffer().set_text(&text);
            }

            SqlEditorInput::ShowFind => {
                if let Some(find) = &self.find {
                    find.open();
                }
            }

            SqlEditorInput::Format => {
                let buffer = self.source_view.buffer();
                let (start, end) = buffer.bounds();
                let text = buffer.text(&start, &end, true).to_string();
                if text.trim().is_empty() {
                    return;
                }
                let driver_id = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
                let Some(grammar) = statement_cursor::grammar_for(&driver_id) else {
                    self.status
                        .set_label(&crate::tr!("Formatting is unavailable for this connection"));
                    return;
                };
                let settings = self.lexing(&driver_id).settings_for(grammar);
                let formatted = format_plan::format_script(&text, grammar, settings);
                if formatted == text {
                    return;
                }
                buffer.set_text(&formatted);
            }
        }
    }
}

impl SqlEditor {
    pub(super) fn execute_sql(
        &mut self,
        trimmed: String,
        planned: PlannedStatements,
        parameter_values: std::collections::HashMap<String, tablepro_core::Value>,
        sender: ComponentSender<Self>,
    ) {
        if !self.can_start_run() || self.session_ending() {
            self.status.set_label(&crate::tr!("Waiting for session to finish"));
            return;
        }
        let origin = crate::services::catalog::CatalogOrigin::capture(self.connection_id, &self.database);
        let conn = match origin.as_ref().and_then(|origin| origin.connection(&self.database)) {
            Some(c) => c,
            None => {
                self.status.set_label(&crate::tr!("no active connection"));
                return;
            }
        };
        let Some(metadata) = self.metadata() else {
            self.status.set_label(&crate::tr!("no active connection"));
            return;
        };
        let Some(generation) = self.run_generation.try_start_new() else {
            return;
        };

        if let Some(prev) = self.cancel_token.take() {
            prev.cancel();
        }
        let token = CancellationToken::new();
        self.cancel_token = Some(token.clone());

        self.set_running(true, conn.supports_server_cancellation(), &sender);
        self.status.set_label(&crate::tr!("Running…"));
        dim_previous_results(&self.results_holder);
        self.streaming = None;
        self.clear_run_marks();

        self.longer_timeout_button.set_visible(false);
        let timeout_secs = self.timeout_retry.resolve(|| {
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id)
        });

        self.executions.insert(
            generation,
            ExecutionContext {
                sql: trimmed.clone(),
                lexical: self.lexing(&metadata.driver_id).settings,
                metadata,
                started_at: SystemTime::now(),
                timeout_secs,
            },
        );

        let export_origin = origin.clone();
        let export_suggested_name = export_name_for_query(&trimmed);
        let driver_id = self
            .executions
            .get(&generation)
            .map(|context| context.metadata.driver_id.clone())
            .unwrap_or_default();
        let export_driver_id = driver_id.clone();
        let target = self.statement_target(conn);
        let lexing_source = self.lexing_source();
        let export_session = StreamSession::of(&target);
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded_with(timeout_secs, token);
                    let succeeded = |sql: &str| {
                        if let Some(origin) = &origin {
                            sender_clone.input(SqlEditorInput::CatalogStatementSucceeded {
                                origin: origin.clone(),
                                driver: driver_id.clone(),
                                sql: sql.into(),
                            });
                        }
                    };
                    let page_sender = sender_clone.clone();
                    let stream_update = move |update| {
                        let sender = page_sender.clone();
                        let export_origin = export_origin.clone();
                        let export_driver_id = export_driver_id.clone();
                        let export_suggested_name = export_suggested_name.clone();
                        let export_session = export_session.clone();
                        Box::pin(async move {
                            match update {
                                StreamUpdate::Started {
                                    identity,
                                    sql_preview,
                                    sql,
                                    params,
                                } => {
                                    let (accepted, delivered) = tokio::sync::oneshot::channel();
                                    sender.input(SqlEditorInput::StreamStarted {
                                        generation,
                                        identity,
                                        sql_preview,
                                        export_query: export_origin.map(|origin| {
                                            crate::ui::export_dialog::StreamExportQuery {
                                                origin,
                                                driver_id: export_driver_id.clone(),
                                                sql,
                                                params,
                                                timeout_secs,
                                                suggested_name: export_suggested_name.clone(),
                                                session: export_session.clone(),
                                            }
                                        }),
                                        accepted,
                                    });
                                    delivered.await.unwrap_or(false)
                                }
                                StreamUpdate::Page { sequence, page } => {
                                    let (accepted, delivered) = tokio::sync::oneshot::channel();
                                    sender.input(SqlEditorInput::StreamPage {
                                        generation,
                                        sequence,
                                        page,
                                        accepted,
                                    });
                                    delivered.await.unwrap_or(false)
                                }
                            }
                        }) as std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>>
                    };
                    let msg = match run_statements_with_stream(
                        StatementRun {
                            target: target.clone(),
                            statements: planned.statements,
                            driver_id: &driver_id,
                            parameter_values: &parameter_values,
                            control: &control,
                            error_policy: planned.error_policy,
                            settings_check: planned.settings_check,
                            succeeded,
                        },
                        stream_update,
                    )
                    .await
                    {
                        ScriptRunResult::Cancelled => SqlEditorInput::ShowCancelled(generation),
                        ScriptRunResult::TimedOut => SqlEditorInput::ShowTimedOut {
                            generation,
                            secs: timeout_secs,
                        },
                        ScriptRunResult::Streamed(terminal) => SqlEditorInput::StreamFinished { generation, terminal },
                        ScriptRunResult::Completed(outcomes) => {
                            let total_ms: u128 = outcomes.iter().map(|o| o.elapsed_ms).sum();
                            let n_ok = outcomes
                                .iter()
                                .filter(|o| {
                                    matches!(o.kind, StatementOutcomeKind::Rows(_))
                                        || matches!(o.kind, StatementOutcomeKind::Streamed(_))
                                })
                                .count();
                            let n_err = outcomes
                                .iter()
                                .filter(|o| matches!(o.kind, StatementOutcomeKind::Error(_)))
                                .count();
                            tracing::info!(n_ok, n_err, total_ms, "script run complete");
                            SqlEditorInput::ShowOutcomes { generation, outcomes }
                        }
                    };
                    sender_clone.input(msg);
                    if let Some((session_id, open, usable)) = target.session_state().await {
                        sender_clone.input(SqlEditorInput::SessionState {
                            session_id,
                            transaction_open: open,
                            usable,
                        });
                    }
                    let refresh_control = crate::services::operation_control::bounded(timeout_secs);
                    if let Ok(settings) = target.lexical_settings(&refresh_control).await {
                        sender_clone.input(SqlEditorInput::LexingRefreshed {
                            source: lexing_source,
                            settings,
                        });
                    }
                })
                .drop_on_shutdown()
        });
    }
}

#[cfg(test)]
mod dispatch_tests;
#[cfg(test)]
mod tests;
