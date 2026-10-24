//! The SQL editor tab. Each run goes through the tab's own editor
//! session, one statement or `GO` batch at a time, and every statement
//! gets a line in the results list.

mod assistant_actions;
mod buffer_edit;
mod completion;
mod editor_actions;
mod editor_file;
mod editor_session_slot;
mod editor_view;
mod find_bar;
mod find_state;
mod format_plan;
mod imp;
mod inline_suggestion;
mod result_item;
mod result_widgets;
mod results_pane;
mod run_history;
mod run_log;
mod run_scope;
mod safe_mode_gate;
mod script_runner;
mod sidebar_policy;
mod significant_tokens;
mod sql_file;
mod statement_cursor;
#[cfg(test)]
mod tests;
mod transaction_dirty;
mod vim_mode;

use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::{RowLimit, UserSql};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tokio_util::sync::CancellationToken;

use self::buffer_edit::{CursorAnchor, replace_all_undoable};
pub(crate) use self::completion::{CompletionScope, read_catalog, tables_named};
pub(crate) use self::editor_file::file_name;
use self::editor_view::EditorView;
use self::imp::RunningScript;
use self::result_widgets::PageActions;
use self::run_log::{EntryKind, RunEvent, RunLog};
use self::run_scope::ScopedText;
use self::script_runner::{RUN_ROW_LIMIT, RunBatch, ScriptRun, plan_batches, run_in_tab};
pub(crate) use self::transaction_dirty::OpenTransaction;
use super::clipboard::{CopyRequest, InClauseRows};
use super::export::{ExportOffer, ExportOrigin, ExportQuery, ExportSource};
use super::grid::{GridMsg, GridSink, present_row_json};
use super::handler_guard::HandlerGuard;
use super::write_confirmation::{self, WriteConfirmation};
use crate::services::active_session::ActiveSession;
use crate::services::history_service::HistoryService;
use crate::services::snippet_library::SnippetLibrary;
use crate::workspace::WorkOutcome;

glib::wrapper! {
    pub struct SqlEditor(ObjectSubclass<imp::SqlEditor>)
        @extends adw::Bin, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

pub struct SqlEditorInit {
    pub initial_query: Option<String>,
    pub settings: Rc<tablepro_storage::AppSettings>,
    pub history: Option<HistoryService>,
    pub tasks: Tasks,
    /// The window's session, which the tab opens its own connection
    /// from on the first run.
    pub session: ActiveSession,
    /// Keeps the process alive while the tab's connection closes.
    pub hold: Rc<dyn ProcessHold>,
    pub close_timeout: Duration,
    pub snippets: Rc<SnippetLibrary>,
}

/// What one run sends, planned before Safe Mode asks about it, so the
/// answer covers exactly what then runs.
struct PlannedRun {
    scoped: ScopedText,
    batches: Vec<RunBatch>,
    policy: tablepro_core::sql_syntax::script::BatchErrorPolicy,
    warnings: Vec<String>,
    grammar: SqlGrammar,
}

pub(crate) struct EditorDeps {
    settings: Rc<tablepro_storage::AppSettings>,
    history: Option<HistoryService>,
    tasks: Tasks,
    session: ActiveSession,
    hold: Rc<dyn ProcessHold>,
    close_timeout: Duration,
    snippets: Rc<SnippetLibrary>,
}

impl SqlEditor {
    pub fn new(init: SqlEditorInit) -> Self {
        let editor: Self = glib::Object::new();
        let imp = editor.imp();
        let _ = imp.deps.set(EditorDeps {
            settings: init.settings.clone(),
            history: init.history,
            tasks: init.tasks,
            session: init.session,
            hold: init.hold,
            close_timeout: init.close_timeout,
            snippets: init.snippets,
        });
        let grammar = editor.grammar();
        let initial_text = init
            .initial_query
            .unwrap_or_else(|| sample_statement(grammar).to_owned());
        let language = source_language(grammar).and_then(|id| sourceview5::LanguageManager::default().language(id));
        let buffer = match language {
            Some(language) => sourceview5::Buffer::with_language(&language),
            None => sourceview5::Buffer::new(None),
        };
        // The text the tab opens with is not an edit to take back.
        buffer.set_text(&initial_text);
        imp.source_view.set_buffer(Some(&buffer));
        imp.find_bar.attach(imp.source_view.upcast_ref());
        let toasts = editor.downgrade();
        imp.find_bar.connect_toast(move |_, text| {
            if let Some(editor) = toasts.upgrade() {
                editor.emit_by_name::<()>("toast", &[&text]);
            }
        });
        editor.connect_theme(&init.settings);
        editor.connect_completion(&buffer);
        editor.connect_buffer(&buffer);
        editor.follow_file_state(&buffer);
        editor.install_actions();
        editor.extend_context_menu();
        // After the editor's own key controllers, so Vim's runs first.
        let vim = editor.follow_vim_preference(&init.settings);
        editor.imp().app_handlers.borrow_mut().push(vim);
        editor.install_drop_target();
        editor.connect_buttons();
        editor.connect_grid();
        editor
    }

    /// The text buffer, so the draft writer can read the script once per
    /// write rather than carrying a copy of it per keystroke.
    pub fn buffer(&self) -> gtk4::TextBuffer {
        self.imp().source_view.buffer()
    }

    pub fn is_running(&self) -> bool {
        self.imp().running.borrow().is_some()
    }

    /// Whether the tab's connection holds a transaction the user opened.
    pub fn has_open_transaction(&self) -> bool {
        self.imp().transaction_dirty.get()
    }

    /// The transaction the results line names. Unlike
    /// `has_open_transaction`, an engine that cannot say has none.
    pub(crate) fn open_transaction(&self) -> Option<OpenTransaction> {
        self.imp().open_transaction.get()
    }

    /// Whether the last run sent a statement that can change what the
    /// catalog lists, so the window reads it again once the run ends.
    pub(crate) fn last_run_changes_catalog(&self) -> bool {
        self.imp().changes_catalog.get()
    }

    /// Stop the running query. The results list says what ran before.
    pub fn stop(&self) {
        if let Some(running) = self.imp().running.borrow().as_ref() {
            running.cancel.cancel();
        }
    }

    /// Put a query from history or a saved query in the buffer, as one
    /// step Ctrl+Z takes back.
    pub fn replace_query(&self, text: &str) {
        let buffer = self.buffer();
        if buffer_text(&buffer) == text {
            return;
        }
        self.imp().source_view.single_caret();
        replace_all_undoable(&buffer, text);
        self.emit_by_name::<()>("undoable-toast", &[&crate::i18n::gettext("Query replaced")]);
    }

    /// Take back the last edit, for a toast's Undo button.
    pub fn undo(&self) {
        let buffer = self.buffer();
        if buffer.can_undo() {
            buffer.undo();
        }
    }

    /// Stop the running query and hand over the tab's connection, so a
    /// teardown closes every tab's at once under one hold.
    pub fn take_editor_session(&self) -> Option<std::sync::Arc<dyn tablepro_core::EditorSession>> {
        let imp = self.imp();
        if imp.shut_down.replace(true) {
            return None;
        }
        if let Some(running) = imp.running.take() {
            running.cancel.cancel();
            running.drain.abort();
        }
        imp.slot.close()
    }

    /// Close the tab's connection. The process is held until the close
    /// ends, so quitting right after closing a tab does not cut it off.
    pub fn shutdown(&self) {
        let (Some(editor), Some(deps)) = (self.take_editor_session(), self.deps()) else {
            return;
        };
        let hold = deps.hold.acquire();
        let closing = tablepro_session::close_editor_sessions(vec![editor], deps.close_timeout, &deps.tasks);
        glib::spawn_future_local(async move {
            match closing.await {
                Ok(reports) => tracing::debug!(?reports, "closed an editor tab's session"),
                Err(failure) => tracing::warn!(%failure, "closing an editor tab's session failed"),
            }
            drop(hold);
        });
    }

    /// Run the selection, or the whole buffer when nothing is selected.
    pub fn run(&self) {
        let buffer = self.buffer();
        let text = buffer_text(&buffer);
        let selection = buffer.selection_bounds().map(|(start, end)| {
            let start = usize::try_from(start.offset()).unwrap_or_default();
            let end = usize::try_from(end.offset()).unwrap_or_default();
            start..end
        });
        match run_scope::for_run(&text, selection) {
            Some(scoped) => self.execute(scoped),
            None => self.say(&crate::i18n::gettext("There is nothing to run.")),
        }
    }

    /// Run the statement the cursor is in, selecting it so the user sees
    /// which of the buffer's queries ran.
    pub fn run_at_cursor(&self) {
        if self.is_running() {
            return;
        }
        let buffer = self.buffer();
        let text = buffer_text(&buffer);
        let plan = statement_cursor::plan_for(&text, self.grammar());
        let cursor = usize::try_from(buffer.iter_at_mark(&buffer.get_insert()).offset()).unwrap_or_default();
        let Some((start, end)) = statement_cursor::statement_bounds_at(&buffer, &plan, &text, cursor) else {
            self.say(&crate::i18n::gettext("No statement at the cursor."));
            return;
        };
        buffer.select_range(&start, &end);
        self.execute(ScopedText {
            text: buffer.text(&start, &end, false).to_string(),
            base_char: usize::try_from(start.offset()).unwrap_or_default(),
        });
    }

    /// Reformat the buffer per statement, as one undo step, keeping the
    /// cursor near where it was.
    pub fn format(&self) {
        let buffer = self.buffer();
        let text = buffer_text(&buffer);
        if text.trim().is_empty() {
            return;
        }
        let grammar = self.grammar();
        // The formatter knows only SQL's layout.
        if !grammar.is_sql() {
            return;
        }
        let settings = tablepro_core::sql_syntax::script::LexicalSettings::default_for(grammar);
        let formatted = format_plan::format_script(&text, grammar, settings);
        if formatted == text {
            return;
        }
        self.imp().source_view.single_caret();
        let anchor = CursorAnchor::capture(&buffer);
        replace_all_undoable(&buffer, &formatted);
        anchor.restore(&buffer);
        self.imp().source_view.scroll_mark_onscreen(&buffer.get_insert());
    }

    /// Read a dropped or chosen file and put it in the buffer: the whole
    /// buffer when it is empty, at the cursor otherwise. A file that
    /// fills the buffer is the one Save writes back to.
    pub async fn insert_file(&self, file: gio::File, replace: bool) {
        let text = match sql_file::load_text(&file).await {
            Ok(text) => text,
            Err(message) => {
                self.emit_by_name::<()>("toast", &[&message]);
                return;
            }
        };
        let buffer = self.buffer();
        self.imp().source_view.single_caret();
        if replace || buffer_text(&buffer).trim().is_empty() {
            replace_all_undoable(&buffer, &text);
            self.opened_file(file);
        } else {
            buffer.begin_user_action();
            buffer.insert_at_cursor(&text);
            buffer.end_user_action();
        }
    }

    pub fn connect_run_state_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "run-state-changed",
            false,
            glib::closure_local!(move |editor: &Self, running: bool| f(editor, running)),
        )
    }

    /// A run ended on its own or was stopped. A tab closed while it runs
    /// says nothing.
    pub(crate) fn connect_run_finished<F: Fn(&Self, crate::workspace::WorkOutcome) + 'static>(
        &self,
        f: F,
    ) -> glib::SignalHandlerId {
        self.connect_closure(
            "run-finished",
            false,
            glib::closure_local!(move |editor: &Self, outcome: crate::workspace::WorkOutcome| f(editor, outcome)),
        )
    }

    pub fn connect_content_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "content-changed",
            false,
            glib::closure_local!(move |editor: &Self| f(editor)),
        )
    }

    pub fn connect_toast<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |editor: &Self, text: String| f(editor, text)),
        )
    }

    /// A toast whose Undo button calls `undo`.
    pub fn connect_undoable_toast<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "undoable-toast",
            false,
            glib::closure_local!(move |editor: &Self, text: String| f(editor, text)),
        )
    }

    pub(crate) fn connect_export_results<F: Fn(&Self, ExportOffer) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "export-results",
            false,
            glib::closure_local!(move |editor: &Self, payload: glib::BoxedAnyObject| {
                f(editor, payload.borrow::<ExportOffer>().clone());
            }),
        )
    }

    pub fn connect_transaction_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "transaction-changed",
            false,
            glib::closure_local!(move |editor: &Self, open: bool| f(editor, open)),
        )
    }

    fn deps(&self) -> Option<&EditorDeps> {
        self.imp().deps.get()
    }

    /// The grammar of the server the editor is pointed at, which decides
    /// where statements begin and end. With no connection the split
    /// still has to work, and PostgreSQL's is the strictest.
    fn grammar(&self) -> SqlGrammar {
        self.deps()
            .and_then(|deps| deps.session.get())
            .and_then(|session| session.current_dialect())
            .map_or(SqlGrammar::PostgreSql, |dialect| dialect.grammar())
    }

    /// A one-line message where the run summary goes.
    fn say(&self, message: &str) {
        let results = &self.imp().results;
        if !self.is_running() {
            results.set_summary(message);
        }
    }

    fn execute(&self, scoped: ScopedText) {
        let imp = self.imp();
        if self.is_running() || imp.shut_down.get() || imp.confirming.get() {
            return;
        }
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(session) = deps.session.get() else {
            self.say(&crate::i18n::gettext("Connect to a database to run a query."));
            return;
        };
        let buffer = self.buffer();
        let base_line = usize::try_from(
            buffer
                .iter_at_offset(i32::try_from(scoped.base_char).unwrap_or(i32::MAX))
                .line(),
        )
        .unwrap_or_default();
        let grammar = self.grammar();
        let (batches, policy, warnings) = plan_batches(&scoped, grammar, base_line);
        if batches.is_empty() {
            self.say(&crate::i18n::gettext("There is nothing to run."));
            return;
        }
        let gated = safe_mode_gate::gate(batches, grammar, session.safe_mode());
        let planned = PlannedRun {
            scoped,
            batches: gated.batches,
            policy,
            warnings,
            grammar,
        };
        if gated.confirm.is_empty() {
            self.start_run(session, planned);
            return;
        }
        let confirmation = WriteConfirmation::statements(&session.metadata().name, &gated.confirm, gated.destructive);
        imp.confirming.set(true);
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let Some(editor) = weak.upgrade() else {
                return;
            };
            let answered = write_confirmation::confirm(editor.upcast_ref(), &confirmation).await;
            editor.imp().confirming.set(false);
            // The answer covers the connection it was asked on.
            let same_session = editor
                .deps()
                .and_then(|deps| deps.session.get())
                .is_some_and(|current| Arc::ptr_eq(&current, &session));
            if answered && same_session && !editor.is_running() && !editor.imp().shut_down.get() {
                editor.start_run(session, planned);
            }
        });
    }

    fn start_run(&self, session: Arc<tablepro_session::Session>, planned: PlannedRun) {
        let imp = self.imp();
        let Some(deps) = self.deps() else {
            return;
        };
        let PlannedRun {
            scoped,
            batches,
            policy,
            warnings,
            grammar,
        } = planned;
        imp.changes_catalog.set(
            batches
                .iter()
                .any(|batch| tablepro_core::sql_syntax::changes_catalog(&batch.text, grammar)),
        );
        let statements = batches.iter().map(|batch| UserSql::new(batch.text.as_str())).collect();
        let run = ScriptRun {
            batches,
            policy,
            statement_timeout: deps.settings.query_timeout(),
            row_limit: RowLimit::EDITOR_DEFAULT,
            run_row_limit: RUN_ROW_LIMIT,
        };
        let metadata = session.metadata().clone();
        // Read again at the end from the run's own session, never the
        // window's: the link can come up during the run, and the window
        // can move to another engine before it ends.
        let dialect = session.current_dialect();
        let ran_on = session.clone();
        let started_at = SystemTime::now();
        let cancel = CancellationToken::new();
        let (events, mut received) = tokio::sync::mpsc::channel(8);
        drop(deps.tasks.spawn_task(run_in_tab(
            session,
            imp.slot.clone(),
            run,
            deps.close_timeout,
            cancel.clone(),
            events,
        )));

        imp.results.clear();
        imp.results.set_running(true);
        imp.results.set_summary(&crate::i18n::gettext("Running…"));
        imp.run_button.set_sensitive(false);
        imp.stop_button.set_visible(true);
        imp.log.replace(Some(RunLog::new(statements, warnings)));
        self.show_new_entries(0);
        self.emit_by_name::<()>("run-state-changed", &[&true]);

        let weak = self.downgrade();
        let query = scoped.text;
        let drain = glib::spawn_future_local(async move {
            while let Some(event) = received.recv().await {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                let finished = matches!(event, RunEvent::Finished);
                editor.apply_event(event);
                if finished {
                    let dialect = dialect.or_else(|| ran_on.current_dialect());
                    editor.finish_run(query, &metadata, started_at, dialect);
                    return;
                }
            }
            // The runner ended without saying so, which only a panic
            // does; the list still has to end and the tab unlock.
            if let Some(editor) = weak.upgrade() {
                editor.apply_event(RunEvent::Finished);
                let dialect = dialect.or_else(|| ran_on.current_dialect());
                editor.finish_run(query, &metadata, started_at, dialect);
            }
        });
        imp.running.replace(Some(RunningScript { cancel, drain }));
    }

    fn apply_event(&self, event: RunEvent) {
        let before = match self.imp().log.borrow_mut().as_mut() {
            Some(log) => log.apply(event),
            None => return,
        };
        self.show_new_entries(before);
    }

    fn show_new_entries(&self, from: usize) {
        let imp = self.imp();
        let log = imp.log.borrow();
        let Some(log) = log.as_ref() else {
            return;
        };
        imp.results.append(log.entries().get(from..).unwrap_or_default());
    }

    fn result_page(&self, index: u32) -> Option<gtk4::Widget> {
        let imp = self.imp();
        let grid_sink = imp.grid_sink.get()?;
        let log = imp.log.borrow();
        let entry = log.as_ref()?.entries().get(usize::try_from(index).ok()?)?;
        let (errors, exports) = (self.downgrade(), self.downgrade());
        let fixes = self.downgrade();
        let available = self
            .imp()
            .assistant
            .borrow()
            .is_some()
            .then(|| imp_action(self, "ai-explain"))
            .flatten();
        let actions = PageActions {
            go_to_error: move |position| {
                if let Some(editor) = errors.upgrade() {
                    editor.go_to_char(position);
                }
            },
            export_all: move |shown| {
                if let Some(editor) = exports.upgrade() {
                    editor.offer_export(index, shown);
                }
            },
            fix: available.map(|available| result_widgets::FixHook {
                run: move || {
                    if let Some(editor) = fixes.upgrade() {
                        editor.fix_with_assistant(index);
                    }
                },
                available,
            }),
        };
        Some(result_widgets::entry_widget(
            usize::try_from(index).ok()?,
            entry,
            grid_sink,
            self.grammar().is_sql(),
            actions,
        ))
    }

    fn finish_run(
        &self,
        query: String,
        metadata: &tablepro_session::ConnectionMetadata,
        started_at: SystemTime,
        dialect: Option<Arc<dyn SqlDialect>>,
    ) {
        let imp = self.imp();
        drop(imp.running.take());
        imp.run_button.set_sensitive(true);
        imp.stop_button.set_visible(false);
        imp.results.set_running(false);
        let (summary, transaction, first, entry, outcome) = {
            let log = imp.log.borrow();
            let Some(log) = log.as_ref() else {
                return;
            };
            (
                log.summary(),
                RunTransaction::of(log),
                log.first_to_show(),
                run_history::history_entry(query, metadata, started_at, log),
                log.outcome(),
            )
        };
        imp.results.set_summary(&summary);
        // The focus stays in the editor, where the summary does not show.
        let priority = match outcome {
            WorkOutcome::Failed => gtk4::AccessibleAnnouncementPriority::High,
            WorkOutcome::Succeeded | WorkOutcome::Cancelled => gtk4::AccessibleAnnouncementPriority::Medium,
        };
        crate::ui::a11y::announce(&*imp.results, &summary, priority);
        imp.results
            .set_transaction(transaction.label.as_deref(), transaction.offers_commit);
        if let Some(first) = first.and_then(|first| u32::try_from(first).ok()) {
            imp.results.select(first);
        }
        let dirty = transaction.dirty;
        let dirty_changed = imp.transaction_dirty.replace(dirty) != dirty;
        // Open to failed keeps the tab dirty, and the window still names
        // the change on its other tabs.
        let open_changed = imp.open_transaction.replace(transaction.open) != transaction.open;
        if dirty_changed || open_changed {
            self.emit_by_name::<()>("transaction-changed", &[&dirty]);
        }
        self.record_history(entry, dialect);
        self.emit_by_name::<()>("run-finished", &[&outcome]);
        self.emit_by_name::<()>("run-state-changed", &[&false]);
    }

    fn record_history(&self, entry: tablepro_storage::query_history::NewEntry, dialect: Option<Arc<dyn SqlDialect>>) {
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(history) = deps.history.as_ref() else {
            return;
        };
        drop(deps.tasks.spawn_task(history.record(entry, dialect)));
    }

    /// Put the cursor where the server says a statement went wrong.
    fn go_to_char(&self, position: usize) {
        let imp = self.imp();
        let buffer = self.buffer();
        let iter = buffer.iter_at_offset(i32::try_from(position).unwrap_or(i32::MAX));
        buffer.place_cursor(&iter);
        imp.source_view.scroll_mark_onscreen(&buffer.get_insert());
        imp.source_view.grab_focus();
    }

    fn connect_theme(&self, settings: &Rc<tablepro_storage::AppSettings>) {
        let view = self.imp().source_view.get().upcast::<sourceview5::View>();
        view.set_monospace(true);
        crate::ui::style_scheme_resolver::apply(&view, &settings.style_scheme());
        let style_manager = adw::StyleManager::default();
        let settings_for_theme = Rc::downgrade(settings);
        let dark = style_manager.connect_dark_notify(glib::clone!(
            #[weak]
            view,
            move |_| {
                if let Some(settings) = settings_for_theme.upgrade() {
                    crate::ui::style_scheme_resolver::apply(&view, &settings.style_scheme());
                }
            }
        ));
        let scheme = settings.gio().connect_changed(
            Some(tablepro_storage::settings::keys::STYLE_SCHEME),
            glib::clone!(
                #[weak]
                view,
                move |settings, key| crate::ui::style_scheme_resolver::apply(&view, &settings.string(key))
            ),
        );
        let mut handlers = vec![
            HandlerGuard::new(&style_manager, dark),
            HandlerGuard::new(settings.gio(), scheme),
        ];
        crate::ui::editor_font_provider::apply(settings);
        for key in [
            tablepro_storage::settings::keys::USE_SYSTEM_FONT,
            tablepro_storage::settings::keys::CUSTOM_FONT,
        ] {
            let settings_for_key = Rc::downgrade(settings);
            let font = settings.gio().connect_changed(Some(key), move |_, _| {
                if let Some(settings) = settings_for_key.upgrade() {
                    crate::ui::editor_font_provider::apply(&settings);
                }
            });
            handlers.push(HandlerGuard::new(settings.gio(), font));
        }
        self.imp().app_handlers.replace(handlers);
    }

    /// The catalog's tables, the SQL keywords and the snippets where the
    /// engine speaks SQL, the engine's own snippets where it does not, and
    /// the words in the document everywhere.
    fn connect_completion(&self, buffer: &sourceview5::Buffer) {
        let completion = self.imp().source_view.completion();
        let mut providers = self.imp().completion_providers.borrow_mut();
        if let Some(deps) = self.deps() {
            let catalog =
                completion::SqlCompletionProvider::new(deps.session.clone(), deps.tasks.clone(), deps.snippets.clone());
            completion.add_provider(&catalog);
            providers.push(catalog.upcast());
        }
        let words = sourceview5::CompletionWords::new(Some(&crate::i18n::pgettext("completion group", "Document")));
        words.register(buffer);
        completion.add_provider(&words);
        providers.push(words.upcast());
    }

    // GtkSourceView before 5.21 never frees a view that has drawn its line
    // numbers, so the closing editor takes back the script and the session.
    // GTK 4.24 gives the input method the view from construction until the
    // view's own dispose, and IBus takes a reference on it, so the view is
    // never disposed unless it drops its input method first
    // (https://github.com/ibus/ibus/issues/2968).
    fn release_view(&self) {
        let view = self.imp().source_view.get();
        view.set_im_module(Some("gtk-im-context-none"));
        let completion = view.completion();
        for provider in self.imp().completion_providers.take() {
            completion.remove_provider(&provider);
        }
        view.set_buffer(Some(&sourceview5::Buffer::new(None)));
    }

    fn connect_buffer(&self, buffer: &sourceview5::Buffer) {
        let imp = self.imp();
        let cursor_info = imp.cursor_info.get();
        let view = imp.source_view.get();
        show_cursor_position(&cursor_info, &view);
        buffer.connect_cursor_position_notify(glib::clone!(
            #[weak]
            cursor_info,
            #[weak]
            view,
            move |_| show_cursor_position(&cursor_info, &view)
        ));
        view.connect_carets_changed(glib::clone!(
            #[weak]
            cursor_info,
            move |view| show_cursor_position(&cursor_info, view)
        ));

        let weak = self.downgrade();
        buffer.connect_changed(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.emit_by_name::<()>("content-changed", &[]);
            }
        });

        let run_button = imp.run_button.get();
        buffer.connect_has_selection_notify(glib::clone!(
            #[weak]
            run_button,
            move |buffer| label_run_button(&run_button, buffer.has_selection())
        ));
    }

    fn connect_buttons(&self) {
        let imp = self.imp();
        let weak = self.downgrade();
        imp.run_button.connect_clicked(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.run();
            }
        });
        let weak = self.downgrade();
        imp.stop_button.connect_clicked(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.stop();
            }
        });
        imp.menu_button.set_icon_name(crate::ui::icons::VIEW_MORE);
    }

    /// Result pages, and the context-menu actions from their grids.
    fn connect_grid(&self) {
        let weak = self.downgrade();
        self.imp()
            .results
            .set_page_builder(move |index| weak.upgrade().and_then(|editor| editor.result_page(index)));
        let weak = self.downgrade();
        let sink: GridSink = std::rc::Rc::new(move |message| {
            let Some(editor) = weak.upgrade() else {
                return;
            };
            match message {
                GridMsg::Copy(request) => editor.copy(request),
                GridMsg::CopyInClause(values) => editor.copy_in_clause(values),
                GridMsg::ShowRowJson(request) => {
                    if let Some(tasks) = editor.deps().map(|deps| deps.tasks.clone()) {
                        let parent = editor.clone().upcast();
                        glib::spawn_future_local(async move {
                            present_row_json(parent, tasks, request).await;
                        });
                    }
                }
                GridMsg::ShowToast(text) => editor.emit_by_name::<()>("toast", &[&text]),
                GridMsg::ExportResults(shown) => {
                    if let Some(index) = editor.imp().results.selected() {
                        editor.offer_export(index, shown);
                    }
                }
                _ => {}
            }
        });
        let _ = self.imp().grid_sink.set(sink);
    }

    /// Render a copy from a result grid off the GTK thread, and toast
    /// how it went.
    fn copy(&self, request: CopyRequest) {
        let Some(tasks) = self.deps().map(|deps| deps.tasks.clone()) else {
            return;
        };
        let editor = self.downgrade();
        crate::ui::clipboard::copy_rows(self, &tasks, request, move |text| {
            if let Some(editor) = editor.upgrade() {
                editor.emit_by_name::<()>("toast", &[&text]);
            }
        });
    }

    /// An IN list in the spelling of the server the editor runs on.
    fn copy_in_clause(&self, values: InClauseRows) {
        let dialect = self
            .deps()
            .and_then(|deps| deps.session.get())
            .and_then(|session| session.current_dialect());
        match dialect {
            Some(dialect) => self.copy(CopyRequest::InClause { dialect, values }),
            None => self.emit_by_name::<()>("toast", &[&crate::i18n::gettext("Connect to a database first.")]),
        }
    }

    /// Ask the window to export the result on line `index`: the rows
    /// its grid shows, or every row its statement returns when run
    /// again.
    fn offer_export(&self, index: u32, shown: ExportSource) {
        let Some(offer) = self.export_offer(index, shown) else {
            return;
        };
        self.emit_by_name::<()>("export-results", &[&glib::BoxedAnyObject::new(offer)]);
    }

    fn export_offer(&self, index: u32, shown: ExportSource) -> Option<ExportOffer> {
        let log = self.imp().log.borrow();
        let entry = log.as_ref()?.entries().get(usize::try_from(index).ok()?)?;
        let EntryKind::ResultSet(result) = &entry.kind else {
            return None;
        };
        Some(ExportOffer {
            origin: ExportOrigin::Editor {
                shown,
                query: ExportQuery::Editor {
                    sql: result.statement.clone(),
                },
                shown_rows: result.row_count() as u64,
                truncated: result.summary.is_truncated(),
            },
            session: self.deps().and_then(|deps| deps.session.get()),
            name: export_name_for_query(&entry.preview),
            target: None,
        })
    }

    fn install_drop_target(&self) {
        let target = gtk4::DropTarget::new(gio::File::static_type(), gtk4::gdk::DragAction::COPY);
        let weak = self.downgrade();
        target.connect_drop(move |_, value, _, _| {
            let (Ok(file), Some(editor)) = (value.get::<gio::File>(), weak.upgrade()) else {
                return false;
            };
            // Adding to what is there keeps the user's work; Ctrl+Z
            // takes the drop back.
            glib::spawn_future_local(async move { editor.insert_file(file, false).await });
            true
        });
        self.imp().source_view.add_controller(target);
    }

    fn open_file(&self) {
        self.replace_after_asking(SqlEditor::choose_file);
    }

    /// Loading replaces what is in the tab, which is where the user's
    /// unrun work lives, so `replace` runs once the user agrees, or
    /// straight away when the tab holds nothing. A file emptied and not
    /// saved still holds a change.
    fn replace_after_asking(&self, replace: impl Fn(&SqlEditor) + 'static) {
        if buffer_text(&self.buffer()).trim().is_empty() && !self.has_unsaved_file_changes() {
            replace(self);
            return;
        }
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Replace the Editor Contents?")),
            Some(&crate::i18n::gettext(
                "The file is loaded into this tab, and what is written here now is replaced. Undo brings it back.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("replace", &crate::i18n::gettext("Replace"));
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let weak = self.downgrade();
        dialog.connect_response(Some("replace"), move |_, _| {
            if let Some(editor) = weak.upgrade() {
                replace(&editor);
            }
        });
        dialog.present(Some(self));
    }

    fn choose_file(&self) {
        let filter = editor_file::sql_filter();
        let filters = gio::ListStore::new::<gtk4::FileFilter>();
        filters.append(&filter);
        let dialog = gtk4::FileDialog::builder()
            .title(crate::i18n::gettext("Open SQL File"))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let parent = self.root().and_downcast::<gtk4::Window>();
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            let Ok(file) = dialog.open_future(parent.as_ref()).await else {
                return;
            };
            if let Some(editor) = weak.upgrade() {
                editor.insert_file(file, true).await;
            }
        });
    }
}

/// One of the tab's own actions, for a widget to follow.
fn imp_action(editor: &SqlEditor, name: &str) -> Option<gio::SimpleAction> {
    editor
        .imp()
        .actions
        .get()?
        .lookup_action(name)
        .and_downcast::<gio::SimpleAction>()
}

struct RunTransaction {
    label: Option<String>,
    offers_commit: bool,
    dirty: bool,
    open: Option<OpenTransaction>,
}

impl RunTransaction {
    fn of(log: &RunLog) -> Self {
        let (lost, state) = (log.lost(), log.transaction());
        Self {
            label: transaction_dirty::transaction_label(lost, state),
            offers_commit: transaction_dirty::offers_commit(lost, state),
            dirty: transaction_dirty::transaction_dirty(lost, state, log.has_run()),
            open: transaction_dirty::open_transaction(lost, state),
        }
    }
}

fn show_cursor_position(label: &gtk4::Label, view: &EditorView) {
    let buffer = view.buffer();
    let iter = buffer.iter_at_mark(&buffer.get_insert());
    let line = (iter.line() + 1).to_string();
    let column = (iter.line_offset() + 1).to_string();
    let count = u32::try_from(view.caret_count()).unwrap_or(u32::MAX);
    label.set_label(&if count > 1 {
        crate::i18n::ngettext_f(
            "Ln {line}, Col {column}, {count} cursor",
            "Ln {line}, Col {column}, {count} cursors",
            count,
            &[("line", &line), ("column", &column), ("count", &count.to_string())],
        )
    } else {
        crate::i18n::gettext_f("Ln {line}, Col {column}", &[("line", &line), ("column", &column)])
    });
}

fn label_run_button(button: &gtk4::Button, has_selection: bool) {
    if has_selection {
        button.set_label(&crate::i18n::gettext("Run Selection"));
        button.set_tooltip_text(Some(&crate::i18n::gettext("Run the Selected Text")));
    } else {
        button.set_label(&crate::i18n::gettext("Run"));
        button.set_tooltip_text(Some(&crate::i18n::gettext("Run the Script")));
    }
}

fn buffer_text(buffer: &impl IsA<gtk4::TextBuffer>) -> String {
    let buffer = buffer.as_ref();
    let (start, end) = buffer.bounds();
    buffer.text(&start, &end, false).to_string()
}

/// The lines each caret's selection covers, or its own line. A selection
/// that ends at column 0 of the next line does not take that line in, as
/// in other editors.
fn commented_lines(ranges: &[(gtk4::TextIter, gtk4::TextIter)]) -> std::collections::BTreeSet<i32> {
    let mut lines = std::collections::BTreeSet::new();
    for (start, end) in ranges {
        let mut last = end.line();
        if end.line_offset() == 0 && last > start.line() {
            last -= 1;
        }
        lines.extend(start.line()..=last);
    }
    lines
}

/// Toggle SQL line-comment (`-- `) for `lines`. If every non-blank line
/// is already commented, strip the prefix; otherwise prepend `-- ` after
/// each line's leading whitespace. Blank lines are skipped in both
/// directions so toggling twice returns the original text, and the whole
/// edit is one undo step.
fn toggle_line_comment(buffer: &gtk4::TextBuffer, lines: &std::collections::BTreeSet<i32>) {
    let lines: Vec<(i32, String)> = lines
        .iter()
        .map(|&l| {
            let Some(s) = buffer.iter_at_line(l) else {
                return (l, String::new());
            };
            let mut e = s;
            e.forward_to_line_end();
            (l, buffer.text(&s, &e, false).to_string())
        })
        .collect();

    let all_commented = lines
        .iter()
        .filter(|(_, l)| !l.trim().is_empty())
        .all(|(_, l)| l.trim_start().starts_with("--"));

    buffer.begin_user_action();
    for (line_n, original) in &lines {
        let line_n = *line_n;
        if original.trim().is_empty() {
            continue;
        }
        let leading_chars: i32 = original.chars().take_while(|c| c.is_whitespace()).count() as i32;
        let Some(mut iter) = buffer.iter_at_line(line_n) else {
            continue;
        };
        iter.forward_chars(leading_chars);

        if all_commented {
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
    crate::i18n::gettext("Empty Query")
}

/// What a new editor tab opens with: a statement that only reads.
fn sample_statement(grammar: SqlGrammar) -> &'static str {
    match grammar {
        SqlGrammar::Redis => "PING",
        SqlGrammar::Mongo => "db.getCollectionNames()",
        _ => "SELECT 1;",
    }
}

/// The GtkSourceView language that colours the editor. MongoDB's shell
/// is JavaScript; GtkSourceView has none for Redis's commands, which show
/// as plain text rather than wrongly coloured as SQL.
fn source_language(grammar: SqlGrammar) -> Option<&'static str> {
    match grammar {
        SqlGrammar::Redis => None,
        SqlGrammar::Mongo => Some("js"),
        _ => Some("sql"),
    }
}
