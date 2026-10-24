//! Suggestions while typing: when the user pauses at the end of a line,
//! the assistant's completion shows as dimmed text after the cursor,
//! laid over the text view rather than written into the buffer. Tab
//! accepts it; Escape, typing or moving the cursor drops it.

use std::time::Duration;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_ai::{ChatMessage, ChatRequest};

use super::SqlEditor;
use super::editor_view::EditorView;
use crate::ui::assistant::AssistantAccess;

/// How long a pause in typing is before a suggestion is asked for.
const PAUSE: Duration = Duration::from_millis(700);
/// A typed key inserts a character or a few, where a paste or a format
/// inserts more and asks for nothing.
const TYPED_CHARS: usize = 3;
/// The text around the cursor a suggestion sees, as the prompt cuts it.
const BEFORE_CHARS: i32 = 4_000;
const AFTER_CHARS: i32 = 1_000;

#[derive(Default)]
pub(crate) struct SuggestionState {
    /// The last change was a key typed.
    typed: bool,
    timer: Option<glib::SourceId>,
    work: Option<glib::JoinHandle<()>>,
    /// Bumped by every change, so a suggestion asked for before it is
    /// not shown.
    generation: u64,
    /// Where the suggestion waited for, asked for or shown goes in. The
    /// cursor leaving it drops the suggestion.
    at: Option<i32>,
    /// The suggestion shown.
    ghost: Option<String>,
    /// Where it shows: the rest of the cursor's line, and the lines after
    /// it, which start where the cursor's line starts. Laid over the view
    /// once and hidden in between, since a text view has no call that
    /// takes an overlay away again.
    labels: Option<[gtk::Label; 2]>,
}

impl SqlEditor {
    pub(super) fn follow_typing_for_suggestions(&self) {
        let buffer = self.buffer();
        let editor = self.downgrade();
        buffer.connect_insert_text(move |_, _, text| {
            if let Some(editor) = editor.upgrade() {
                editor.imp().suggestion.borrow_mut().typed = text.chars().count() <= TYPED_CHARS;
            }
        });
        let editor = self.downgrade();
        buffer.connect_changed(move |_| {
            if let Some(editor) = editor.upgrade() {
                let typed = std::mem::take(&mut editor.imp().suggestion.borrow_mut().typed);
                editor.dismiss_suggestion();
                if typed {
                    editor.schedule_suggestion();
                }
            }
        });
        let editor = self.downgrade();
        buffer.connect_cursor_position_notify(move |buffer| {
            let Some(editor) = editor.upgrade() else {
                return;
            };
            let moved = editor
                .imp()
                .suggestion
                .borrow()
                .at
                .is_some_and(|at| at != buffer.cursor_position());
            if moved {
                editor.dismiss_suggestion();
            }
        });
        let editor = self.downgrade();
        // Vim's normal mode, and overwrite, are not typing.
        self.imp().source_view.connect_overwrite_notify(move |view| {
            if view.overwrites()
                && let Some(editor) = editor.upgrade()
            {
                editor.dismiss_suggestion();
            }
        });
        let editor = self.downgrade();
        // A suggestion goes in at GTK's cursor alone, as a completion does.
        self.imp().source_view.connect_carets_changed(move |view| {
            if view.has_extra_carets()
                && let Some(editor) = editor.upgrade()
            {
                editor.dismiss_suggestion();
            }
        });
        let view = self.imp().source_view.get();
        view.add_controller(self.suggestion_keys());
        let focus = gtk::EventControllerFocus::new();
        let editor = self.downgrade();
        focus.connect_leave(move |_| {
            if let Some(editor) = editor.upgrade() {
                editor.dismiss_suggestion();
            }
        });
        view.add_controller(focus);
    }

    /// Tab takes the suggestion in; Escape drops it and goes on to the
    /// editor, so Vim still leaves insert mode on it.
    fn suggestion_keys(&self) -> gtk::EventControllerKey {
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let editor = self.downgrade();
        keys.connect_key_pressed(move |_, keyval, _, state| {
            let Some(editor) = editor.upgrade() else {
                return glib::Propagation::Proceed;
            };
            // The completion list, when it is open, takes Tab first.
            if editor.imp().suggestion.borrow().ghost.is_none() || editor.imp().source_view.shows_popup() {
                return glib::Propagation::Proceed;
            }
            if crate::application::component_matches("suggestion.accept", keyval, state) {
                editor.accept_suggestion();
                return glib::Propagation::Stop;
            }
            if crate::application::component_matches("suggestion.dismiss", keyval, state) {
                editor.dismiss_suggestion();
            }
            glib::Propagation::Proceed
        });
        keys
    }

    /// Drop the suggestion shown and any on its way.
    pub(super) fn dismiss_suggestion(&self) {
        let mut state = self.imp().suggestion.borrow_mut();
        state.generation += 1;
        state.at = None;
        if let Some(timer) = state.timer.take() {
            timer.remove();
        }
        if let Some(work) = state.work.take() {
            work.abort();
        }
        state.ghost = None;
        for label in state.labels.iter().flatten() {
            label.set_visible(false);
        }
    }

    /// Drop the suggestion when the assistant may no longer send from
    /// here, after a policy or preference change.
    pub(super) fn check_suggestion(&self) {
        let allowed = self
            .imp()
            .assistant
            .borrow()
            .as_ref()
            .is_some_and(|access| access.suggests_while_typing());
        if !allowed {
            self.dismiss_suggestion();
        }
    }

    pub(crate) fn suggestion_text(&self) -> Option<String> {
        self.imp().suggestion.borrow().ghost.clone()
    }

    fn schedule_suggestion(&self) {
        let allowed = self
            .imp()
            .assistant
            .borrow()
            .as_ref()
            .is_some_and(|access| access.suggests_while_typing());
        if !allowed {
            return;
        }
        let editor = self.downgrade();
        let timer = glib::timeout_add_local_once(PAUSE, move || {
            if let Some(editor) = editor.upgrade() {
                // The source is gone once it has run.
                editor.imp().suggestion.borrow_mut().timer.take();
                editor.request_suggestion();
            }
        });
        let mut state = self.imp().suggestion.borrow_mut();
        state.timer = Some(timer);
        state.at = Some(self.buffer().cursor_position());
    }

    pub(super) fn request_suggestion(&self) {
        let Some(access) = self.imp().assistant.borrow().clone() else {
            return;
        };
        if !access.suggests_while_typing() || self.is_running() || !self.is_typing_mode() {
            return;
        }
        let buffer = self.buffer();
        if buffer.has_selection() || self.imp().source_view.has_extra_carets() {
            return;
        }
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        let mut line_end = cursor;
        if !line_end.ends_line() {
            line_end.forward_to_line_end();
        }
        if !buffer.text(&cursor, &line_end, false).trim().is_empty() {
            return;
        }
        // Only the window the prompt carries is read, however long the
        // script: this runs on the GTK thread at every pause.
        let offset = cursor.offset();
        let window_start = buffer.iter_at_offset((offset - BEFORE_CHARS).max(0));
        let window_end = buffer.iter_at_offset(offset.saturating_add(AFTER_CHARS));
        let before = buffer.text(&window_start, &cursor, false).to_string();
        let after = buffer.text(&cursor, &window_end, false).to_string();
        if before.trim().is_empty() {
            return;
        }
        let generation = self.imp().suggestion.borrow().generation;
        let editor = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let suggestion = suggest(&access, &before, &after).await;
            let Some(editor) = editor.upgrade() else {
                return;
            };
            {
                let mut state = editor.imp().suggestion.borrow_mut();
                if state.generation != generation {
                    return;
                }
                // This is that work, so it is let go rather than stopped.
                drop(state.work.take());
            }
            if let Some(text) = suggestion {
                editor.show_suggestion(text, offset, !after.trim().is_empty());
            }
        });
        self.imp().suggestion.borrow_mut().work = Some(work);
    }

    fn show_suggestion(&self, text: String, offset: i32, more_below: bool) {
        let buffer = self.buffer();
        let still_allowed = self
            .imp()
            .assistant
            .borrow()
            .as_ref()
            .is_some_and(|access| access.suggests_while_typing());
        let view = self.imp().source_view.get();
        if !still_allowed
            || buffer.cursor_position() != offset
            || buffer.has_selection()
            || !self.is_typing_mode()
            || view.shows_popup()
            || view.has_extra_carets()
        {
            return;
        }
        // A label over the text would hide the lines under the cursor,
        // so with text below only the rest of this line is suggested.
        let text = if more_below {
            text.split('\n').next().unwrap_or_default().to_owned()
        } else {
            text
        };
        if text.trim().is_empty() {
            return;
        }
        let cursor = buffer.iter_at_offset(offset);
        let place = view.iter_location(&cursor);
        let mut line_start = cursor;
        line_start.set_line_offset(0);
        let origin = view.iter_location(&line_start);
        let (first, rest) = text.split_once('\n').unwrap_or((text.as_str(), ""));
        let [line, below] = self.ghost_labels();
        show_ghost(&view, &line, first, place.x(), place.y());
        show_ghost(&view, &below, rest, origin.x(), place.y() + place.height());
        crate::ui::a11y::announce(
            &view,
            &crate::i18n::gettext_f("Suggestion: {text}. Tab accepts it.", &[("text", &text)]),
            gtk::AccessibleAnnouncementPriority::Low,
        );
        let mut state = self.imp().suggestion.borrow_mut();
        state.ghost = Some(text);
        state.at = Some(offset);
    }

    fn ghost_labels(&self) -> [gtk::Label; 2] {
        if let Some(labels) = self.imp().suggestion.borrow().labels.clone() {
            return labels;
        }
        let view = self.imp().source_view.get();
        let labels = [ghost_label(&view), ghost_label(&view)];
        self.imp().suggestion.borrow_mut().labels = Some(labels.clone());
        labels
    }

    /// Whether keys typed now insert text: not in Vim's normal mode, and
    /// not in overwrite, which Vim also uses for its other modes.
    fn is_typing_mode(&self) -> bool {
        !self.imp().source_view.overwrites()
    }

    pub(crate) fn accept_suggestion(&self) {
        let Some(text) = self.suggestion_text() else {
            return;
        };
        self.dismiss_suggestion();
        let buffer = self.buffer();
        buffer.begin_user_action();
        buffer.insert_at_cursor(&text);
        buffer.end_user_action();
        self.imp().source_view.scroll_mark_onscreen(&buffer.get_insert());
    }
}

/// Dimmed text laid over the view, in the editor's font, which the
/// label takes from the view. Hidden until a suggestion shows in it.
fn ghost_label(view: &EditorView) -> gtk::Label {
    let label = gtk::Label::builder()
        .xalign(0.0)
        .can_target(false)
        .can_focus(false)
        .visible(false)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    label.add_css_class("dim-label");
    view.add_overlay(&label, 0, 0);
    label
}

/// Show `text` in `label` at buffer position `x`, `y`; an empty one hides it.
fn show_ghost(view: &EditorView, label: &gtk::Label, text: &str, x: i32, y: i32) {
    label.set_label(text);
    view.move_overlay(label, x, y);
    label.set_visible(!text.is_empty());
}

/// The assistant's completion at the cursor, or `None` when there is
/// none to show. A failure is logged, never shown: the user did not ask.
async fn suggest(access: &AssistantAccess, before: &str, after: &str) -> Option<String> {
    let endpoint = match access.ai().endpoint().await {
        Ok(endpoint) => endpoint,
        Err(error) => {
            tracing::debug!(%error, "no suggestion: the provider is not ready");
            return None;
        }
    };
    let context = access.context(format!("{before}{after}")).await;
    let request = ChatRequest {
        system: tablepro_ai::completion_system_prompt(&context),
        messages: vec![ChatMessage::user(tablepro_ai::completion_message(before, after))],
        max_tokens: ChatRequest::SUGGESTION_MAX_TOKENS,
    };
    if access.ai().prepare().await.is_err() {
        return None;
    }
    // The preferences or the policy may have changed meanwhile.
    if !access.suggests_while_typing() || !access.may_send_to(&endpoint) {
        return None;
    }
    match access.ai().complete(endpoint, request).await {
        Ok((text, _)) => tablepro_ai::clean_completion(&text, before),
        Err(error) => {
            tracing::debug!(%error, "no suggestion");
            None
        }
    }
}

#[cfg(test)]
mod suggestion_tests {
    use std::time::Duration;

    use tablepro_core::AiPolicy;

    use super::*;
    use crate::ui::editor::assistant_actions::tests::editor_with_assistant;

    fn at_end(editor: &SqlEditor) -> i32 {
        let buffer = editor.buffer();
        buffer.place_cursor(&buffer.end_iter());
        buffer.cursor_position()
    }

    #[gtk4::test]
    fn tab_takes_a_suggestion_in_as_one_undo_step() {
        let harness = editor_with_assistant("SELECT * FROM", AiPolicy::Allow);
        harness.settings.get().set_ai_inline_suggestions(true).expect("on");
        let editor = &harness.editor;
        let offset = at_end(editor);

        editor.show_suggestion(" orders;".to_owned(), offset, false);
        assert_eq!(editor.suggestion_text().as_deref(), Some(" orders;"));
        editor.accept_suggestion();

        assert_eq!(
            crate::ui::editor::buffer_text(&editor.buffer()),
            "SELECT * FROM orders;"
        );
        assert_eq!(editor.suggestion_text(), None);
        editor.buffer().undo();
        assert_eq!(crate::ui::editor::buffer_text(&editor.buffer()), "SELECT * FROM");
    }

    #[gtk4::test]
    fn moving_the_cursor_or_a_policy_of_never_drops_it() {
        let harness = editor_with_assistant("SELECT * FROM", AiPolicy::Allow);
        harness.settings.get().set_ai_inline_suggestions(true).expect("on");
        let editor = &harness.editor;
        let offset = at_end(editor);
        editor.show_suggestion(" orders;".to_owned(), offset, false);

        let buffer = editor.buffer();
        buffer.place_cursor(&buffer.start_iter());
        assert_eq!(editor.suggestion_text(), None, "a cursor move keeps it");

        let offset = at_end(editor);
        harness.policy.set(AiPolicy::Never);
        editor.show_suggestion(" orders;".to_owned(), offset, false);
        assert_eq!(editor.suggestion_text(), None, "shown under Never");
    }

    #[gtk4::test]
    fn a_dropped_suggestion_leaves_no_text_over_the_editor() {
        let harness = editor_with_assistant("SELECT * FROM", AiPolicy::Allow);
        harness.settings.get().set_ai_inline_suggestions(true).expect("on");
        let editor = &harness.editor;
        let shown = || {
            crate::test_support::descendants(&editor.imp().source_view.get())
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
                .filter(|label| label.is_visible() && label.has_css_class("dim-label"))
                .map(|label| label.label().to_string())
                .collect::<Vec<_>>()
        };

        let offset = at_end(editor);
        editor.show_suggestion(" orders\nWHERE id = 1;".to_owned(), offset, false);
        assert_eq!(shown(), [" orders", "WHERE id = 1;"]);
        editor.buffer().place_cursor(&editor.buffer().start_iter());
        assert!(shown().is_empty(), "{:?}", shown());

        let offset = at_end(editor);
        editor.show_suggestion(" orders;".to_owned(), offset, false);
        assert_eq!(shown(), [" orders;"]);
    }

    #[gtk4::test]
    fn with_text_below_only_the_rest_of_the_line_is_suggested() {
        let harness = editor_with_assistant("SELECT *\n\nSELECT 2;", AiPolicy::Allow);
        harness.settings.get().set_ai_inline_suggestions(true).expect("on");
        let editor = &harness.editor;
        let buffer = editor.buffer();
        buffer.place_cursor(&buffer.iter_at_offset(8));

        editor.show_suggestion(" FROM orders\nWHERE id = 1;".to_owned(), 8, true);

        assert_eq!(editor.suggestion_text().as_deref(), Some(" FROM orders"));
    }

    #[gtk4::test]
    fn another_cursor_drops_it_and_none_shows_beside_one() {
        let harness = editor_with_assistant("SELECT a FROM a", AiPolicy::Allow);
        harness.settings.get().set_ai_inline_suggestions(true).expect("on");
        let editor = &harness.editor;
        let view = editor.imp().source_view.get();
        let offset = at_end(editor);
        editor.show_suggestion(" WHERE a = 1;".to_owned(), offset, false);

        assert!(view.add_carets_at_all_matches());
        assert_eq!(editor.suggestion_text(), None, "kept beside a cursor at each match");

        view.single_caret();
        let buffer = editor.buffer();
        buffer.place_cursor(&buffer.end_iter());
        view.toggle_caret_at(&buffer.start_iter());
        assert!(view.has_extra_carets());
        editor.show_suggestion(" WHERE a = 1;".to_owned(), buffer.cursor_position(), false);
        assert_eq!(editor.suggestion_text(), None, "shown beside another cursor");
    }

    #[gtk4::test]
    fn a_pause_in_typing_asks_the_provider_and_shows_its_answer() {
        let harness = editor_with_assistant("SELECT * FROM", AiPolicy::Allow);
        let provider = crate::ui::assistant::fake_provider::serve(
            &harness.runtime,
            concat!(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"orders;\"},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n",
            ),
        );
        let settings = harness.settings.get();
        settings.set_ai_inline_suggestions(true).expect("on");
        settings
            .set_ai_compatible_url(&format!("http://127.0.0.1:{}/v1", provider.port))
            .expect("the address");
        settings
            .set_ai_model(tablepro_core::AiProvider::OpenAiCompatible, "llama3.2")
            .expect("the model");
        let editor = &harness.editor;
        at_end(editor);

        editor.buffer().insert_at_cursor(" ");
        crate::test_support::wait_until(Duration::from_secs(10), || editor.suggestion_text().is_some())
            .expect("a suggestion");

        assert_eq!(editor.suggestion_text().as_deref(), Some("orders;"));
        let body = provider.bodies.lock().expect("the bodies")[0].clone();
        assert!(body.contains("Text before the cursor"), "{body}");
    }
}
