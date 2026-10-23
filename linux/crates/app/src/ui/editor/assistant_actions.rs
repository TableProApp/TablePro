//! What the editor asks the assistant: Explain, Review and Optimize on
//! the statement Run would run, and Fix on one the server refused.

use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_ai::Action;

use super::SqlEditor;
use super::run_log::EntryKind;
use crate::ui::assistant::{AssistantAccess, AssistantRequest, Availability};

/// The editor's actions that send a statement to the assistant.
pub(super) const ASSISTANT_ACTIONS: [(&str, Action); 3] = [
    ("ai-explain", Action::Explain),
    ("ai-review", Action::Review),
    ("ai-optimize", Action::Optimize),
];

impl SqlEditor {
    /// Let the tab ask the window's assistant. Without it the actions
    /// stay hidden.
    pub(crate) fn attach_assistant(&self, access: Rc<AssistantAccess>) {
        self.imp().assistant.replace(Some(access));
        if self.grammar().is_sql() {
            self.follow_typing_for_suggestions();
        }
        self.refresh_assistant();
    }

    /// The assistant's items after the text view's own, such as
    /// GtkSourceView's Change Case, which setting the menu would replace.
    pub(super) fn extend_context_menu(&self) {
        let view = self.imp().source_view.get();
        let menu = gio::Menu::new();
        if let Some(own) = view.extra_menu() {
            menu.append_section(None, &own);
        }
        menu.append_section(None, &self.imp().assistant_menu.get());
        view.set_extra_menu(Some(&menu));
    }

    /// Show or hide what the assistant offers, after the provider or the
    /// connection's policy changed.
    pub(crate) fn refresh_assistant(&self) {
        let ready = self.assistant_ready();
        if let Some(actions) = self.imp().actions.get() {
            for (name, _) in ASSISTANT_ACTIONS {
                if let Some(action) = actions.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                    action.set_enabled(ready);
                }
            }
        }
        self.check_suggestion();
    }

    pub(super) fn assistant_ready(&self) -> bool {
        self.grammar().is_sql()
            && self
                .imp()
                .assistant
                .borrow()
                .as_ref()
                .is_some_and(|access| access.availability() == Availability::Ready)
    }

    pub(super) fn ask_assistant(&self, action: Action) {
        if !self.assistant_ready() {
            return;
        }
        match self.statement_for_assistant() {
            Some(statement) => self.request_assistant(AssistantRequest {
                action,
                statement,
                error: None,
            }),
            None => self.say(&crate::i18n::gettext("No statement at the cursor.")),
        }
    }

    /// The selection, or the statement the cursor is in: what Run would
    /// run, never the whole tab.
    fn statement_for_assistant(&self) -> Option<String> {
        let buffer = self.buffer();
        if let Some((start, end)) = buffer.selection_bounds() {
            let selected = buffer.text(&start, &end, false).to_string();
            if !selected.trim().is_empty() {
                return Some(selected.trim().to_owned());
            }
        }
        let text = super::buffer_text(&buffer);
        let plan = super::statement_cursor::plan_for(&text, self.grammar());
        let cursor = usize::try_from(buffer.iter_at_mark(&buffer.get_insert()).offset()).unwrap_or_default();
        let (start, mut end) = super::statement_cursor::statement_bounds_at(&buffer, &plan, &text, cursor)?;
        // The statement's range stops before its terminator, which the
        // assistant should see as the user wrote it.
        let mut after = end;
        while after.char().is_whitespace() && after.char() != '\n' && after.forward_char() {}
        if after.char() == ';' {
            after.forward_char();
            end = after;
        }
        let statement = buffer.text(&start, &end, false).to_string();
        let statement = statement.trim();
        (!statement.is_empty()).then(|| statement.to_owned())
    }

    /// Ask for a fix of the statement on result line `index`, with the
    /// server's error.
    pub(super) fn fix_with_assistant(&self, index: u32) {
        let request = {
            let log = self.imp().log.borrow();
            let Some(log) = log.as_ref() else {
                return;
            };
            let Some(entry) = usize::try_from(index).ok().and_then(|index| log.entries().get(index)) else {
                return;
            };
            let EntryKind::Failed { message, .. } = &entry.kind else {
                return;
            };
            let Some(statement) = entry.batch.and_then(|batch| log.statement(batch)) else {
                return;
            };
            AssistantRequest {
                action: Action::Fix,
                statement: statement.trim().to_owned(),
                error: Some(message.clone()),
            }
        };
        if self.assistant_ready() {
            self.request_assistant(request);
        }
    }

    fn request_assistant(&self, request: AssistantRequest) {
        self.emit_by_name::<()>("assistant-requested", &[&glib::BoxedAnyObject::new(request)]);
    }

    pub(crate) fn connect_assistant_requested<F: Fn(&Self, AssistantRequest) + 'static>(
        &self,
        f: F,
    ) -> glib::SignalHandlerId {
        self.connect_closure(
            "assistant-requested",
            false,
            glib::closure_local!(move |editor: &Self, payload: glib::BoxedAnyObject| {
                f(editor, payload.borrow::<AssistantRequest>().clone());
            }),
        )
    }

    /// Put code from the assistant where the user is working: over the
    /// selection, or at the cursor, as one step Ctrl+Z takes back.
    pub(crate) fn insert_from_assistant(&self, code: &str) {
        let buffer = self.buffer();
        buffer.begin_user_action();
        buffer.delete_selection(true, true);
        buffer.insert_at_cursor(code);
        buffer.end_user_action();
        let view = self.imp().source_view.get();
        view.scroll_mark_onscreen(&buffer.get_insert());
        view.grab_focus();
    }
}

#[cfg(test)]
pub(super) mod tests {
    use std::cell::{Cell, RefCell};

    use tablepro_core::{AiPolicy, AiProvider};

    use super::*;
    use crate::services::active_session::ActiveSession;
    use crate::services::ai_service::AiService;
    use crate::test_support::{MemorySettings, test_runtime};
    use crate::ui::editor::SqlEditorInit;

    pub(in crate::ui::editor) struct Harness {
        pub editor: SqlEditor,
        pub policy: Rc<Cell<AiPolicy>>,
        pub settings: MemorySettings,
        pub runtime: crate::runtime::AppRuntime,
    }

    /// An editor whose window's assistant answers from `provider`.
    pub(in crate::ui::editor) fn editor_with_assistant(text: &str, policy: AiPolicy) -> Harness {
        crate::register_test_resources();
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .expect("the provider");
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: Some(text.to_owned()),
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: ActiveSession::new(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            close_timeout: std::time::Duration::from_secs(5),
            snippets: crate::test_support::builtin_snippets_only(),
        });
        let policy = Rc::new(Cell::new(policy));
        let read = policy.clone();
        let service = AiService::new(settings.get().clone(), runtime.tasks(), None);
        editor.attach_assistant(AssistantAccess::new(
            service,
            ActiveSession::new(),
            "SQLite".to_owned(),
            move || read.get(),
        ));
        Harness {
            editor,
            policy,
            settings,
            runtime,
        }
    }

    fn enabled(editor: &SqlEditor, name: &str) -> bool {
        editor
            .imp()
            .actions
            .get()
            .and_then(|actions| actions.lookup_action(name))
            .is_some_and(|action| action.is_enabled())
    }

    fn requests(editor: &SqlEditor) -> Rc<RefCell<Vec<AssistantRequest>>> {
        let asked = Rc::new(RefCell::new(Vec::new()));
        let kept = asked.clone();
        editor.connect_assistant_requested(move |_, request| kept.borrow_mut().push(request));
        asked
    }

    fn menu_labels(menu: &gio::MenuModel) -> Vec<String> {
        let mut labels = Vec::new();
        for item in 0..menu.n_items() {
            if let Some(label) = menu
                .item_attribute_value(item, "label", None)
                .and_then(|label| label.get::<String>())
            {
                labels.push(label);
            }
            for link in ["section", "submenu"] {
                if let Some(inner) = menu.item_link(item, link) {
                    labels.extend(menu_labels(&inner));
                }
            }
        }
        labels
    }

    #[gtk4::test]
    fn the_context_menu_keeps_the_views_own_items() {
        let harness = editor_with_assistant("SELECT 1;", AiPolicy::Ask);

        let menu = harness.editor.imp().source_view.extra_menu().expect("the context menu");
        let labels = menu_labels(&menu);

        assert!(labels.iter().any(|label| label == "C_hange Case"), "{labels:?}");
        assert!(labels.iter().any(|label| label == "Explain with AI"), "{labels:?}");
    }

    #[gtk4::test]
    fn the_actions_stay_hidden_without_an_assistant_that_may_send() {
        crate::register_test_resources();
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let bare = SqlEditor::new(SqlEditorInit {
            initial_query: Some("SELECT 1;".to_owned()),
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: ActiveSession::new(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            close_timeout: std::time::Duration::from_secs(5),
            snippets: crate::test_support::builtin_snippets_only(),
        });
        let harness = editor_with_assistant("SELECT 1;", AiPolicy::Ask);

        assert!(!enabled(&bare, "ai-explain"));
        assert!(enabled(&harness.editor, "ai-explain"));

        harness.policy.set(AiPolicy::Never);
        harness.editor.refresh_assistant();
        assert!(!enabled(&harness.editor, "ai-review"));

        harness.policy.set(AiPolicy::Allow);
        harness.settings.get().set_ai_provider(None).expect("off");
        harness.editor.refresh_assistant();
        assert!(!enabled(&harness.editor, "ai-optimize"));
    }

    #[gtk4::test]
    fn explain_sends_the_statement_at_the_cursor_and_not_the_whole_tab() {
        let harness = editor_with_assistant("SELECT 1;\nSELECT name\nFROM users;\nSELECT 3;", AiPolicy::Allow);
        let asked = requests(&harness.editor);
        let buffer = harness.editor.buffer();
        buffer.place_cursor(&buffer.iter_at_offset(15));

        WidgetExt::activate_action(&harness.editor, "editor.ai-explain", None).expect("the action");

        assert_eq!(
            asked.borrow().as_slice(),
            [AssistantRequest {
                action: Action::Explain,
                statement: "SELECT name\nFROM users;".to_owned(),
                error: None,
            }]
        );
    }

    #[gtk4::test]
    fn review_sends_the_selection_when_there_is_one() {
        let harness = editor_with_assistant("SELECT a FROM t WHERE b = 1;", AiPolicy::Allow);
        let asked = requests(&harness.editor);
        let buffer = harness.editor.buffer();
        buffer.select_range(&buffer.iter_at_offset(0), &buffer.iter_at_offset(15));

        WidgetExt::activate_action(&harness.editor, "editor.ai-review", None).expect("the action");

        assert_eq!(asked.borrow()[0].statement, "SELECT a FROM t");
        assert_eq!(asked.borrow()[0].action, Action::Review);
        drop(harness.runtime);
    }

    #[gtk4::test]
    fn inserted_code_replaces_the_selection_as_one_undo_step() {
        let harness = editor_with_assistant("SELEC 1;", AiPolicy::Allow);
        let buffer = harness.editor.buffer();
        buffer.select_range(&buffer.start_iter(), &buffer.end_iter());

        harness.editor.insert_from_assistant("SELECT 1;");

        assert_eq!(crate::ui::editor::buffer_text(&buffer), "SELECT 1;");
        buffer.undo();
        assert_eq!(crate::ui::editor::buffer_text(&buffer), "SELEC 1;");
    }
}
