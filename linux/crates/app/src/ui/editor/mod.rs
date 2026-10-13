//! The SQL editor tab. Each run goes through the tab's own editor
//! session, one statement or `GO` batch at a time, and every statement
//! gets a line in the results list.

mod buffer_edit;
mod completion;
mod editor_session_slot;
mod format_plan;
mod imp;
mod result_item;
mod result_widgets;
mod results_pane;
mod run_history;
mod run_log;
mod run_scope;
mod script_runner;
mod sidebar_policy;
mod significant_tokens;
mod sql_file;
mod statement_cursor;
#[cfg(test)]
mod tests;
mod transaction_dirty;

use std::rc::Rc;
use std::time::{Duration, SystemTime};

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use sourceview5::prelude::*;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::{QueryResult, RowLimit};
use tablepro_session::runtime::{ProcessHold, Tasks};
use tokio_util::sync::CancellationToken;

use self::buffer_edit::{CursorAnchor, replace_all_undoable};
use self::imp::RunningScript;
use self::run_log::{RunEvent, RunLog};
use self::run_scope::ScopedText;
use self::script_runner::{ScriptRun, plan_batches, run_in_tab};
use super::grid::GridMsg;
use super::handler_guard::HandlerGuard;
use crate::services::active_session::ActiveSession;

glib::wrapper! {
    pub struct SqlEditor(ObjectSubclass<imp::SqlEditor>)
        @extends adw::Bin, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

pub struct SqlEditorInit {
    pub initial_query: Option<String>,
    pub settings: Rc<tablepro_storage::AppSettings>,
    pub history: Option<tablepro_storage::QueryHistory>,
    pub tasks: Tasks,
    /// The window's session, which the tab opens its own connection
    /// from on the first run.
    pub session: ActiveSession,
    /// Keeps the process alive while the tab's connection closes.
    pub hold: Rc<dyn ProcessHold>,
    pub close_timeout: Duration,
}

pub(crate) struct EditorDeps {
    settings: Rc<tablepro_storage::AppSettings>,
    history: Option<tablepro_storage::QueryHistory>,
    tasks: Tasks,
    session: ActiveSession,
    hold: Rc<dyn ProcessHold>,
    close_timeout: Duration,
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
        });
        let initial_text = init.initial_query.unwrap_or_else(|| "SELECT 1;".to_owned());
        let buffer = match sourceview5::LanguageManager::default().language("sql") {
            Some(language) => sourceview5::Buffer::with_language(&language),
            None => sourceview5::Buffer::new(None),
        };
        // The text the tab opens with is not an edit to take back.
        buffer.set_text(&initial_text);
        imp.source_view.set_buffer(Some(&buffer));
        editor.connect_theme(&init.settings);
        editor.connect_completion(&buffer);
        editor.connect_buffer(&buffer);
        editor.install_actions();
        editor.install_shortcuts();
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

    /// Close the tab's connection. The process is held until the close
    /// ends, so quitting right after closing a tab does not cut it off.
    pub fn shutdown(&self) {
        let imp = self.imp();
        if imp.shut_down.replace(true) {
            return;
        }
        if let Some(running) = imp.running.take() {
            running.cancel.cancel();
            running.drain.abort();
        }
        let (Some(editor), Some(deps)) = (imp.slot.close(), imp.deps.get()) else {
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
        let settings = tablepro_core::sql_syntax::script::LexicalSettings::default_for(grammar);
        let formatted = format_plan::format_script(&text, grammar, settings);
        if formatted == text {
            return;
        }
        let anchor = CursorAnchor::capture(&buffer);
        replace_all_undoable(&buffer, &formatted);
        anchor.restore(&buffer);
        self.imp().source_view.scroll_mark_onscreen(&buffer.get_insert());
    }

    /// Read a dropped or chosen file and put it in the buffer: the whole
    /// buffer when it is empty, at the cursor otherwise.
    pub async fn insert_file(&self, file: gio::File, replace: bool) {
        let text = match sql_file::load_text(&file).await {
            Ok(text) => text,
            Err(message) => {
                self.emit_by_name::<()>("toast", &[&message]);
                return;
            }
        };
        let buffer = self.buffer();
        if replace || buffer_text(&buffer).trim().is_empty() {
            replace_all_undoable(&buffer, &text);
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

    pub fn connect_query_changed<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "query-changed",
            false,
            glib::closure_local!(move |editor: &Self, text: String| f(editor, text)),
        )
    }

    pub fn connect_copy_to_clipboard<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "copy-to-clipboard",
            false,
            glib::closure_local!(move |editor: &Self, text: String| f(editor, text)),
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

    pub fn connect_export_results<F: Fn(&Self, QueryResult, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "export-results",
            false,
            glib::closure_local!(move |editor: &Self, payload: glib::BoxedAnyObject| {
                let (result, name) = payload.borrow::<(QueryResult, String)>().clone();
                f(editor, result, name);
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

    /// The SQL grammar of the server the editor is pointed at, which
    /// decides where statements begin and end. With no connection the
    /// split still has to work, and PostgreSQL's is the strictest.
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
        if self.is_running() || imp.shut_down.get() {
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
        let (batches, policy, warnings) = plan_batches(&scoped, self.grammar(), base_line);
        if batches.is_empty() {
            self.say(&crate::i18n::gettext("There is nothing to run."));
            return;
        }
        let previews = batches.iter().map(|batch| batch.preview.clone()).collect();
        let run = ScriptRun {
            batches,
            policy,
            statement_timeout: deps.settings.query_timeout(),
            row_limit: RowLimit::EDITOR_DEFAULT,
        };
        let metadata = session.metadata().clone();
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
        imp.log.replace(Some(RunLog::new(previews, warnings)));
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
                    editor.finish_run(query, &metadata, started_at);
                    return;
                }
            }
            // The runner ended without saying so, which only a panic
            // does; the list still has to end and the tab unlock.
            if let Some(editor) = weak.upgrade() {
                editor.apply_event(RunEvent::Finished);
                editor.finish_run(query, &metadata, started_at);
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
        let grid_sender = imp.grid_sender.get()?;
        let log = imp.log.borrow();
        let entry = log.as_ref()?.entries().get(usize::try_from(index).ok()?)?;
        let weak = self.downgrade();
        Some(result_widgets::entry_widget(entry, grid_sender, move |position| {
            if let Some(editor) = weak.upgrade() {
                editor.go_to_char(position);
            }
        }))
    }

    fn finish_run(&self, query: String, metadata: &tablepro_session::ConnectionMetadata, started_at: SystemTime) {
        let imp = self.imp();
        drop(imp.running.take());
        imp.run_button.set_sensitive(true);
        imp.stop_button.set_visible(false);
        imp.results.set_running(false);
        let (summary, label, dirty, first, entry) = {
            let log = imp.log.borrow();
            let Some(log) = log.as_ref() else {
                return;
            };
            (
                log.summary(),
                transaction_dirty::transaction_label(log.transaction()),
                transaction_dirty::transaction_dirty(log.lost(), log.transaction(), log.has_run()),
                log.first_to_show(),
                run_history::history_entry(query, metadata, started_at, log),
            )
        };
        imp.results.set_summary(&summary);
        imp.results.set_transaction(label.as_deref());
        if let Some(first) = first.and_then(|first| u32::try_from(first).ok()) {
            imp.results.select(first);
        }
        if imp.transaction_dirty.replace(dirty) != dirty {
            self.emit_by_name::<()>("transaction-changed", &[&dirty]);
        }
        self.record_history(entry);
        self.emit_by_name::<()>("run-state-changed", &[&false]);
    }

    fn record_history(&self, entry: tablepro_storage::query_history::NewEntry) {
        let Some(deps) = self.deps() else {
            return;
        };
        let Some(history) = deps.history.clone() else {
            return;
        };
        drop(deps.tasks.spawn_task(async move {
            if let Err(error) = history.record(entry).await {
                tracing::warn!(%error, "history record failed");
            }
        }));
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
        let view = self.imp().source_view.get();
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

    fn connect_completion(&self, buffer: &sourceview5::Buffer) {
        let completion = self.imp().source_view.completion();
        if let Some(deps) = self.deps() {
            let catalog = completion::SqlCompletionProvider::new(deps.session.clone(), deps.tasks.clone());
            completion.add_provider(&catalog);
        }
        let words = sourceview5::CompletionWords::new(Some(&crate::i18n::pgettext("completion group", "Document")));
        words.register(buffer);
        completion.add_provider(&words);
    }

    fn connect_buffer(&self, buffer: &sourceview5::Buffer) {
        let imp = self.imp();
        let cursor_info = imp.cursor_info.get();
        show_cursor_position(&cursor_info, buffer);
        buffer.connect_cursor_position_notify(glib::clone!(
            #[weak]
            cursor_info,
            move |buffer| show_cursor_position(&cursor_info, buffer)
        ));

        let weak = self.downgrade();
        buffer.connect_changed(move |buffer| {
            if let Some(editor) = weak.upgrade() {
                editor.emit_by_name::<()>("query-changed", &[&buffer_text(buffer)]);
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
        let (sender, receiver) = relm4::channel::<GridMsg>();
        let _ = self.imp().grid_sender.set(sender);
        let weak = self.downgrade();
        glib::spawn_future_local(async move {
            while let Some(message) = receiver.recv().await {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                match message {
                    GridMsg::CopyToClipboard(text) => editor.emit_by_name::<()>("copy-to-clipboard", &[&text]),
                    GridMsg::ShowToast(text) => editor.emit_by_name::<()>("toast", &[&text]),
                    GridMsg::ExportResults(result) => {
                        let name = export_name_for_query(&editor.selected_preview());
                        let payload = glib::BoxedAnyObject::new((result, name));
                        editor.emit_by_name::<()>("export-results", &[&payload]);
                    }
                    _ => {}
                }
            }
        });
    }

    /// The statement behind the result on screen, to name its export.
    fn selected_preview(&self) -> String {
        let imp = self.imp();
        let index = imp.results.selected().unwrap_or(0) as usize;
        imp.log
            .borrow()
            .as_ref()
            .and_then(|log| log.entries().get(index).map(|entry| entry.preview.clone()))
            .unwrap_or_default()
    }

    fn install_actions(&self) {
        let actions = gio::SimpleActionGroup::new();
        let weak = self.downgrade();
        let open = gio::ActionEntry::builder("open-file")
            .activate(move |_: &gio::SimpleActionGroup, _, _| {
                if let Some(editor) = weak.upgrade() {
                    editor.open_file();
                }
            })
            .build();
        let weak = self.downgrade();
        let format = gio::ActionEntry::builder("format")
            .activate(move |_: &gio::SimpleActionGroup, _, _| {
                if let Some(editor) = weak.upgrade() {
                    editor.format();
                }
            })
            .build();
        actions.add_action_entries([open, format]);
        self.insert_action_group("editor", Some(&actions));
    }

    fn install_shortcuts(&self) {
        let controller = gtk4::ShortcutController::new();
        let shortcut = |key, modifiers, act: fn(&SqlEditor)| {
            let weak = self.downgrade();
            gtk4::Shortcut::builder()
                .trigger(&gtk4::KeyvalTrigger::new(key, modifiers))
                .action(&gtk4::CallbackAction::new(move |_, _| {
                    if let Some(editor) = weak.upgrade() {
                        act(&editor);
                    }
                    glib::Propagation::Stop
                }))
                .build()
        };
        let control = gtk4::gdk::ModifierType::CONTROL_MASK;
        let control_shift = control | gtk4::gdk::ModifierType::SHIFT_MASK;
        controller.add_shortcut(shortcut(gtk4::gdk::Key::Return, control, SqlEditor::run));
        // Esc stops a running query; the editor is not a dialog, so Esc
        // is otherwise free, and it is the key a user reaches for when a
        // query runs away.
        controller.add_shortcut(shortcut(
            gtk4::gdk::Key::Escape,
            gtk4::gdk::ModifierType::empty(),
            SqlEditor::stop,
        ));
        controller.add_shortcut(shortcut(gtk4::gdk::Key::f, control_shift, SqlEditor::format));
        controller.add_shortcut(shortcut(
            gtk4::gdk::Key::Return,
            control_shift,
            SqlEditor::run_at_cursor,
        ));
        controller.add_shortcut(shortcut(gtk4::gdk::Key::slash, control, |editor| {
            toggle_line_comment(&editor.buffer());
        }));
        self.imp().source_view.add_controller(controller);
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
        if buffer_text(&self.buffer()).trim().is_empty() {
            self.choose_file();
            return;
        }
        // Loading replaces what is in the tab, which is where the user's
        // unrun work lives, so it asks first.
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
                editor.choose_file();
            }
        });
        dialog.present(Some(self));
    }

    fn choose_file(&self) {
        let filter = gtk4::FileFilter::new();
        filter.set_name(Some(&crate::i18n::gettext("SQL files")));
        filter.add_suffix("sql");
        filter.add_mime_type("application/sql");
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

fn show_cursor_position(label: &gtk4::Label, buffer: &sourceview5::Buffer) {
    let iter = buffer.iter_at_mark(&buffer.get_insert());
    label.set_label(&crate::i18n::gettext_f(
        "Ln {line}, Col {column}",
        &[
            ("line", &(iter.line() + 1).to_string()),
            ("column", &(iter.line_offset() + 1).to_string()),
        ],
    ));
}

fn label_run_button(button: &gtk4::Button, has_selection: bool) {
    if has_selection {
        button.set_label(&crate::i18n::gettext("Run Selection"));
        button.set_tooltip_text(Some(&crate::i18n::gettext("Run the selected text (Ctrl+Return)")));
    } else {
        button.set_label(&crate::i18n::gettext("Run"));
        button.set_tooltip_text(Some(&crate::i18n::gettext("Run the script (Ctrl+Return)")));
    }
}

fn buffer_text(buffer: &impl IsA<gtk4::TextBuffer>) -> String {
    let buffer = buffer.as_ref();
    let (start, end) = buffer.bounds();
    buffer.text(&start, &end, false).to_string()
}

/// Toggle SQL line-comment (`-- `) for the lines in the buffer's
/// current selection (or the cursor's line when nothing is selected).
/// If every non-blank line in the range is already commented, strip
/// the prefix; otherwise prepend `-- ` after each line's leading
/// whitespace. Blank lines are skipped in both directions so toggling
/// twice returns the original text, and the whole edit is one undo step.
fn toggle_line_comment(buffer: &gtk4::TextBuffer) {
    let (sel_start, sel_end) = buffer.selection_bounds().unwrap_or_else(|| {
        let i = buffer.iter_at_mark(&buffer.get_insert());
        (i, i)
    });
    let start_line = sel_start.line();
    let mut end_line = sel_end.line();
    // A selection that ends at column 0 of the next line does not take
    // that line in, as in other editors.
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
    crate::i18n::gettext("Empty query")
}
