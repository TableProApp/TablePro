use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::find_bar::Direction;
use super::run_scope::ScopedText;
use super::{OpenTransaction, SqlEditor, commented_lines, toggle_line_comment};
use crate::application::{ShortcutOwner, local_shortcut_controller};

impl SqlEditor {
    /// The tab's `editor` group, the source view's keys for it, and the
    /// buttons' accessible keys.
    pub(super) fn install_actions(&self) {
        let actions = gio::SimpleActionGroup::new();
        let entry = |name: &'static str, act: fn(&SqlEditor)| {
            let weak = self.downgrade();
            gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
                .activate(move |_, _, _| {
                    if let Some(editor) = weak.upgrade() {
                        act(&editor);
                    }
                })
                .build()
        };
        actions.add_action_entries([
            entry("open-file", SqlEditor::open_file),
            entry("save", SqlEditor::save),
            entry("save-as", SqlEditor::save_as),
            entry("run", SqlEditor::run),
            entry("run-statement", SqlEditor::run_at_cursor),
            entry("cancel", SqlEditor::close_popup_or_stop),
            entry("format", SqlEditor::format),
            entry("toggle-comment", SqlEditor::toggle_comment),
            entry("find", |editor| editor.imp().find_bar.open(false)),
            entry("find-replace", |editor| editor.imp().find_bar.open(true)),
            entry("find-next", |editor| editor.imp().find_bar.find(Direction::Next)),
            entry("find-previous", |editor| {
                editor.imp().find_bar.find(Direction::Previous)
            }),
            entry("commit", SqlEditor::commit),
            entry("roll-back", SqlEditor::confirm_roll_back),
            entry("add-cursor-next-match", |editor| {
                editor.add_carets(|view| view.add_caret_at_next_match());
            }),
            entry("add-cursors-all-matches", |editor| {
                editor.add_carets(|view| view.add_carets_at_all_matches());
            }),
            entry("add-cursor-above", |editor| {
                editor.add_carets(|view| view.add_caret_on_next_line(false));
            }),
            entry("add-cursor-below", |editor| {
                editor.add_carets(|view| view.add_caret_on_next_line(true));
            }),
            entry("single-cursor", SqlEditor::close_popup_or_single_cursor),
        ]);
        for (name, action) in super::assistant_actions::ASSISTANT_ACTIONS {
            let weak = self.downgrade();
            let entry = gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
                .activate(move |_, _, _| {
                    if let Some(editor) = weak.upgrade() {
                        editor.ask_assistant(action);
                    }
                })
                .build();
            actions.add_action_entries([entry]);
            // Hidden until a workspace attaches an assistant that may send.
            set_enabled(&actions, name, false);
        }
        sync_run_actions(&actions, false, None);
        sync_caret_actions(&actions, &self.imp().source_view);
        // Commands have no comments, and no layout to format them into.
        let sql = self.grammar().is_sql();
        set_enabled(&actions, "format", sql);
        set_enabled(&actions, "toggle-comment", sql);
        self.insert_action_group("editor", Some(&actions));
        let _ = self.imp().actions.set(actions.clone());
        let carets = actions.clone();
        self.imp()
            .source_view
            .connect_carets_changed(move |view| sync_caret_actions(&carets, view));
        self.connect_run_state_changed(move |editor, running| {
            sync_run_actions(&actions, running, editor.open_transaction());
        });

        let imp = self.imp();
        self.watch_escape();
        imp.text_pane.add_controller(imp.source_view.caret_keys());
        imp.source_view
            .add_controller(local_shortcut_controller(ShortcutOwner::SqlEditor));
        // Added last, so it runs first: Escape returns to one cursor before
        // it stops a query.
        imp.source_view
            .add_controller(local_shortcut_controller(ShortcutOwner::SqlEditorCursors));
        // On the tab, so the find keys work from the find bar's entries too.
        self.add_controller(local_shortcut_controller(ShortcutOwner::SqlEditorTab));
        crate::ui::a11y::announce_key_shortcuts(&imp.run_button.get(), "editor.run");
        crate::ui::a11y::announce_key_shortcuts(&imp.stop_button.get(), "editor.cancel");
        crate::ui::a11y::announce_key_shortcuts(
            imp.source_view.upcast_ref::<gtk4::Widget>(),
            "paned.cycle-child-focus",
        );
    }
}

impl SqlEditor {
    // Sent as typed SQL is, so the results, the history and the
    // transaction line follow it. The buffer keeps the user's script.
    fn commit(&self) {
        let ending = if self.grammar().is_sql() { "COMMIT" } else { "EXEC" };
        self.end_transaction(ending);
    }

    fn roll_back(&self) {
        let ending = if self.grammar().is_sql() { "ROLLBACK" } else { "DISCARD" };
        self.end_transaction(ending);
    }

    fn end_transaction(&self, sql: &str) {
        self.execute(ScopedText {
            text: sql.to_owned(),
            base_char: 0,
        });
    }

    fn confirm_roll_back(&self) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Roll Back the Transaction?")),
            Some(&crate::i18n::gettext("Its uncommitted changes are discarded.")),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("roll-back", &crate::i18n::gettext("Roll Back"));
        dialog.set_response_appearance("roll-back", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let weak = self.downgrade();
        dialog.connect_response(Some("roll-back"), move |_, _| {
            if let Some(editor) = weak.upgrade() {
                editor.roll_back();
            }
        });
        dialog.present(Some(self));
    }

    /// Escape while a query runs. A popup the view has open, such as the
    /// completion list, closes first, as the view's Escape would.
    fn close_popup_or_stop(&self) {
        if !self.closes_a_popup() {
            self.stop();
        }
    }

    /// Escape with more than one cursor, enabled only then.
    fn close_popup_or_single_cursor(&self) {
        if !self.closes_a_popup() && self.imp().source_view.single_caret() {
            self.announce_carets();
        }
    }

    fn closes_a_popup(&self) -> bool {
        let found = self.imp().escape_found_popup.take();
        close_view_popups(&self.imp().source_view.get()) || found
    }

    /// The completion list adds its key controller to the view when it
    /// first shows, after the editor's, so it runs first. A controller on
    /// the pane runs before any of the view's.
    fn watch_escape(&self) {
        let keys = gtk4::EventControllerKey::new();
        keys.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let editor = self.downgrade();
        keys.connect_key_pressed(move |_, keyval, _, _| {
            if let Some(editor) = editor.upgrade() {
                let imp = editor.imp();
                let popup = keyval == gtk4::gdk::Key::Escape && imp.source_view.shows_popup();
                imp.escape_found_popup.set(popup);
            }
            gtk4::glib::Propagation::Proceed
        });
        self.imp().text_pane.add_controller(keys);
    }

    fn add_carets(&self, add: impl FnOnce(&super::EditorView) -> bool) {
        if add(&self.imp().source_view) {
            self.announce_carets();
        }
    }

    /// The other cursors do not show to a screen reader, so the status
    /// line that counts them says how many there are.
    fn announce_carets(&self) {
        let imp = self.imp();
        let count = u32::try_from(imp.source_view.caret_count()).unwrap_or(u32::MAX);
        crate::ui::a11y::announce(
            &imp.cursor_info.get(),
            &crate::i18n::ngettext_f(
                "{count} cursor",
                "{count} cursors",
                count,
                &[("count", &count.to_string())],
            ),
            gtk4::AccessibleAnnouncementPriority::Medium,
        );
    }

    /// Ctrl+/ on every cursor's lines, as one edit.
    fn toggle_comment(&self) {
        let view = self.imp().source_view.get();
        let lines = commented_lines(&view.caret_ranges());
        let buffer = self.buffer();
        view.edit_once(|| toggle_line_comment(&buffer, &lines));
    }

    pub(super) fn refresh_caret_actions(&self) {
        if let Some(actions) = self.imp().actions.get() {
            sync_caret_actions(actions, &self.imp().source_view);
        }
    }
}

/// GtkSourceView parents its completion list and other assistants to
/// the view as popovers, and its Escape hides every visible one.
fn close_view_popups(view: &impl IsA<gtk4::Widget>) -> bool {
    let mut closed = false;
    let mut child = view.as_ref().first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        if widget.is::<gtk4::Popover>() && widget.is_visible() {
            widget.set_visible(false);
            closed = true;
        }
    }
    closed
}

/// Cancel is off while nothing runs, so Escape goes on to the view and
/// its completion popup. The session takes one run at a time, so a
/// commit or rollback waits for the run in flight.
fn sync_run_actions(actions: &gio::SimpleActionGroup, running: bool, open: Option<OpenTransaction>) {
    set_enabled(actions, "cancel", running);
    set_enabled(actions, "roll-back", !running && open.is_some());
    set_enabled(actions, "commit", !running && open == Some(OpenTransaction::Open));
}

/// Vim mode edits the buffer itself, which no other cursor could follow,
/// and Escape goes on to the view while there is one cursor.
fn sync_caret_actions(actions: &gio::SimpleActionGroup, view: &super::EditorView) {
    let enabled = view.carets_enabled();
    for name in [
        "add-cursor-next-match",
        "add-cursors-all-matches",
        "add-cursor-above",
        "add-cursor-below",
    ] {
        set_enabled(actions, name, enabled);
    }
    set_enabled(actions, "single-cursor", view.has_extra_carets());
}

fn set_enabled(actions: &gio::SimpleActionGroup, name: &str, enabled: bool) {
    if let Some(action) = actions.lookup_action(name).and_downcast::<gio::SimpleAction>() {
        action.set_enabled(enabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// GtkSourceView's completion list is a popover child of the view,
    /// which GtkTextView will not take from a test; any widget holds
    /// one the same way.
    #[gtk4::test]
    fn escape_closes_a_shown_popup_and_says_so() {
        let parent = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        let _window = crate::test_support::OwnedWindow::presented(gtk4::Window::builder().child(&parent).build());
        let popup = gtk4::Popover::new();
        popup.set_parent(&parent);
        assert!(!close_view_popups(&parent), "nothing was open");

        popup.set_visible(true);

        assert!(close_view_popups(&parent));
        assert!(!popup.is_visible());
        popup.unparent();
    }
}
