use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use sourceview5::prelude::*;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

use super::SqlEditor;
use super::editor_file::WriteFailure;
use crate::ui::handler_guard::HandlerGuard;

pub(crate) struct VimMode {
    context: sourceview5::VimIMContext,
    keys: gtk4::EventControllerKey,
    bindings: [glib::Binding; 2],
    mode: glib::SignalHandlerId,
    completion_blocked: Rc<Cell<bool>>,
}

/// GtkSourceView runs `:w` and `:e` itself and leaves these to the
/// application.
#[derive(Debug, Clone, PartialEq, Eq)]
enum TabCommand {
    /// `:q!` too: the close prompts also guard an open transaction, which
    /// `!` says nothing about.
    Close,
    WriteAndClose,
    /// `:x` writes only when the file has changes.
    WriteChangesAndClose,
    /// `:w!` may replace another file.
    ForceWrite(Option<String>),
    /// `:e!` drops the tab's text without asking.
    ForceEdit(Option<String>),
}

impl TabCommand {
    fn parse(command: &str) -> Option<Self> {
        let line = command.strip_prefix(':')?.trim();
        let (name, argument) = match line.split_once(char::is_whitespace) {
            Some((name, rest)) => (name, Some(rest.trim().to_owned())),
            None => (line, None),
        };
        let (name, bang) = match name.strip_suffix('!') {
            Some(name) => (name, true),
            None => (name, false),
        };
        match (name, bang, argument) {
            ("q" | "qu" | "qui" | "quit", _, None) => Some(Self::Close),
            ("wq", _, None) => Some(Self::WriteAndClose),
            ("x" | "xi" | "xit" | "exi" | "exit", _, None) => Some(Self::WriteChangesAndClose),
            ("w" | "write", true, argument) => Some(Self::ForceWrite(argument)),
            ("e" | "edit", true, argument) => Some(Self::ForceEdit(argument)),
            _ => None,
        }
    }
}

impl SqlEditor {
    pub(super) fn follow_vim_preference(&self, settings: &Rc<AppSettings>) -> HandlerGuard {
        self.set_vim(settings.vim_keybindings());
        let editor = self.downgrade();
        let handler = settings
            .gio()
            .connect_changed(Some(keys::VIM_KEYBINDINGS), move |settings, key| {
                if let Some(editor) = editor.upgrade() {
                    editor.set_vim(settings.boolean(key));
                }
            });
        HandlerGuard::new(settings.gio(), handler)
    }

    pub(super) fn has_vim(&self) -> bool {
        self.imp().vim.borrow().is_some()
    }

    #[cfg(test)]
    pub(super) fn vim_context(&self) -> Option<sourceview5::VimIMContext> {
        self.imp().vim.borrow().as_ref().map(|vim| vim.context.clone())
    }

    fn set_vim(&self, on: bool) {
        match (on, self.has_vim()) {
            (true, false) => self.attach_vim(),
            (false, true) => self.detach_vim(),
            _ => {}
        }
    }

    fn attach_vim(&self) {
        let imp = self.imp();
        let view = imp.source_view.get();
        let context = sourceview5::VimIMContext::new();
        context.set_client_widget(Some(&view));
        let bindings = [
            context
                .bind_property("command-bar-text", &*imp.vim_command_bar, "label")
                .sync_create()
                .build(),
            context
                .bind_property("command-text", &*imp.vim_command, "label")
                .sync_create()
                .build(),
        ];
        self.connect_vim_commands(&context);

        let keys = gtk4::EventControllerKey::new();
        keys.set_name(Some("tablepro-vim"));
        keys.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let filter = context.clone();
        let kept = crate::application::editor_kept_keys();
        let editor = self.downgrade();
        keys.connect_key_pressed(move |keys, keyval, _, state| {
            let Some(event) = keys.current_event() else {
                return glib::Propagation::Proceed;
            };
            // Tab takes a suggestion in, whichever controller runs first.
            if crate::application::component_matches("suggestion.accept", keyval, state)
                && editor
                    .upgrade()
                    .is_some_and(|editor| editor.suggestion_text().is_some())
            {
                return glib::Propagation::Proceed;
            }
            if kept
                .as_ref()
                .is_some_and(|kept| kept.trigger(&event, false) != gdk::KeyMatch::None)
            {
                return glib::Propagation::Proceed;
            }
            if filter.filter_keypress(&event) {
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        // GTK runs a widget's last controller first, so this one runs
        // before the editor's own keys, which it lets through.
        view.add_controller(keys.clone());

        // Completion belongs to insert mode: a list left open in normal
        // mode would follow motions and edits that are not typing. Vim
        // turns overwrite off in insert mode only.
        let completion_blocked = Rc::new(Cell::new(false));
        follow_insert_mode(view.upcast_ref(), &completion_blocked);
        let blocked = completion_blocked.clone();
        let mode = view.connect_overwrite_notify(move |view| follow_insert_mode(view.upcast_ref(), &blocked));

        imp.text_pane.set_reveal_bottom_bars(true);
        // Vim edits the buffer itself, which no other cursor could follow.
        view.set_carets_enabled(false);
        // Escape is Vim's now; the Stop button still stops a run.
        imp.stop_button.reset_property(gtk4::AccessibleProperty::KeyShortcuts);
        imp.vim.replace(Some(VimMode {
            context,
            keys,
            bindings,
            mode,
            completion_blocked,
        }));
        self.refresh_caret_actions();
    }

    pub(super) fn detach_vim(&self) {
        let imp = self.imp();
        let Some(vim) = imp.vim.take() else {
            return;
        };
        let view = imp.source_view.get();
        view.remove_controller(&vim.keys);
        view.disconnect(vim.mode);
        for binding in vim.bindings {
            binding.unbind();
        }
        vim.context.reset();
        vim.context.set_client_widget(None::<&gtk4::Widget>);
        if vim.completion_blocked.get() {
            view.completion().unblock_interactive();
        }
        // Normal mode draws a block cursor through overwrite, and the
        // command line hides the cursor.
        view.set_overwrite(false);
        view.set_cursor_visible(true);
        imp.vim_command_bar.set_label("");
        imp.vim_command.set_label("");
        imp.text_pane.set_reveal_bottom_bars(false);
        crate::ui::a11y::announce_key_shortcuts(&imp.stop_button.get(), "editor.cancel");
        view.set_carets_enabled(true);
        self.refresh_caret_actions();
    }

    fn connect_vim_commands(&self, context: &sourceview5::VimIMContext) {
        let editor = self.downgrade();
        context.connect_execute_command(move |_, command| {
            let (Some(editor), Some(command)) = (editor.upgrade(), TabCommand::parse(command)) else {
                return false;
            };
            editor.run_tab_command(command);
            true
        });
        // Command completion leaves a space after the name, so `:w ` and
        // `:e ` arrive with an empty path.
        let editor = self.downgrade();
        context.connect_write(move |_, _, path| {
            if let Some(editor) = editor.upgrade() {
                match named(path) {
                    Some(path) => editor.write_named(path, false),
                    None => editor.save(),
                }
            }
        });
        let editor = self.downgrade();
        context.connect_edit(move |_, _, path| {
            if let Some(editor) = editor.upgrade() {
                match named(path) {
                    Some(path) => editor.edit_named(path, false),
                    None => editor.reload_file(false),
                }
            }
        });
    }

    fn run_tab_command(&self, command: TabCommand) {
        match command {
            TabCommand::Close => self.request_close(),
            TabCommand::WriteChangesAndClose if self.file().is_some() && !self.has_unsaved_file_changes() => {
                self.request_close();
            }
            TabCommand::WriteAndClose | TabCommand::WriteChangesAndClose => {
                self.save_then(SqlEditor::request_close);
            }
            TabCommand::ForceWrite(None) => self.save(),
            TabCommand::ForceWrite(Some(path)) => self.write_named(&path, true),
            TabCommand::ForceEdit(None) => self.reload_file(true),
            TabCommand::ForceEdit(Some(path)) => self.edit_named(&path, true),
        }
    }

    fn request_close(&self) {
        self.emit_by_name::<()>("close-requested", &[]);
    }

    pub(crate) fn connect_close_requested<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "close-requested",
            false,
            glib::closure_local!(move |editor: &Self| f(editor)),
        )
    }

    /// Save As to the named file. Unlike Save As it cannot ask, so
    /// without `!` it leaves another file of that name alone, as Vim does.
    fn write_named(&self, typed: &str, replace: bool) {
        let file = typed_file(typed, self.file().as_ref());
        let editor = self.clone();
        glib::spawn_future_local(async move {
            let own = editor.file().is_some_and(|tab| tab.equal(&file));
            if replace || own {
                editor.write_reporting(&file).await;
                return;
            }
            match editor.write_new(&file).await {
                Ok(()) => {}
                Err(WriteFailure::Io(error)) if error.matches(gio::IOErrorEnum::Exists) => {
                    editor.emit_by_name::<()>(
                        "toast",
                        &[&crate::i18n::gettext_f(
                            "“{name}” already exists. Use :w! to replace it.",
                            &[("name", &super::file_name(&file))],
                        )],
                    );
                }
                Err(failure) => editor.alert_save_failed(&failure.message(&file)),
            }
        });
    }

    fn edit_named(&self, typed: &str, force: bool) {
        let file = typed_file(typed, self.file().as_ref());
        if force {
            self.load_file(file);
        } else {
            self.replace_after_asking(move |editor| editor.load_file(file.clone()));
        }
    }

    fn reload_file(&self, force: bool) {
        let Some(file) = self.file() else {
            self.emit_by_name::<()>("toast", &[&crate::i18n::gettext("This tab is not saved to a file.")]);
            return;
        };
        if force || !self.has_unsaved_file_changes() {
            self.load_file(file);
        } else {
            self.replace_after_asking(move |editor| editor.load_file(file.clone()));
        }
    }

    fn load_file(&self, file: gio::File) {
        let editor = self.clone();
        glib::spawn_future_local(async move { editor.insert_file(file, true).await });
    }
}

fn named(path: Option<&str>) -> Option<&str> {
    path.map(str::trim).filter(|path| !path.is_empty())
}

/// Blocking cancels the list and its pending results too, which only
/// hiding the list would leave to reopen it.
fn follow_insert_mode(view: &sourceview5::View, blocked: &Cell<bool>) {
    let block = view.overwrites();
    if block == blocked.get() {
        return;
    }
    let completion = view.completion();
    if block {
        completion.block_interactive();
    } else {
        completion.unblock_interactive();
    }
    blocked.set(block);
}

/// A relative name is next to the tab's file, which may be a remote
/// location, or in the home folder when the tab has none, never in the
/// app's working folder.
fn typed_file(typed: &str, tab_file: Option<&gio::File>) -> gio::File {
    if glib::Uri::peek_scheme(typed).is_some() {
        return gio::File::for_uri(typed);
    }
    let home = glib::home_dir();
    let path = match typed.strip_prefix('~') {
        Some("") => home.clone(),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => PathBuf::from(typed),
    };
    if path.is_absolute() {
        return gio::File::for_path(path);
    }
    tab_file
        .and_then(|file| file.parent())
        .unwrap_or_else(|| gio::File::for_path(home))
        .resolve_relative_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_quit_and_write_commands_act_on_the_tab() {
        for (typed, command) in [
            (":q", TabCommand::Close),
            (":quit", TabCommand::Close),
            (":qu", TabCommand::Close),
            (":q!", TabCommand::Close),
            (":quit!", TabCommand::Close),
            (":q ", TabCommand::Close),
            (":wq", TabCommand::WriteAndClose),
            (":wq!", TabCommand::WriteAndClose),
            (":x", TabCommand::WriteChangesAndClose),
            (":xit", TabCommand::WriteChangesAndClose),
            (":exit", TabCommand::WriteChangesAndClose),
            (":x!", TabCommand::WriteChangesAndClose),
        ] {
            assert_eq!(TabCommand::parse(typed), Some(command), "{typed}");
        }
    }

    #[test]
    fn the_bang_forms_of_write_and_edit_act_on_the_tab() {
        for (typed, command) in [
            (":w!", TabCommand::ForceWrite(None)),
            (":write!", TabCommand::ForceWrite(None)),
            (":w! a.sql", TabCommand::ForceWrite(Some("a.sql".to_owned()))),
            (
                ":w!  my query.sql ",
                TabCommand::ForceWrite(Some("my query.sql".to_owned())),
            ),
            (":e!", TabCommand::ForceEdit(None)),
            (":edit!", TabCommand::ForceEdit(None)),
            (":e! a.sql", TabCommand::ForceEdit(Some("a.sql".to_owned()))),
        ] {
            assert_eq!(TabCommand::parse(typed), Some(command), "{typed}");
        }
    }

    #[test]
    fn other_commands_stay_with_gtksourceview() {
        for typed in [
            ":w", ":write", ":w a.sql", ":e", ":e a.sql", ":set nu", ":s/a/b/", "q", ":", ":qa", ":ex", ":q a.sql",
        ] {
            assert_eq!(TabCommand::parse(typed), None, "{typed}");
        }
    }

    #[test]
    fn a_typed_name_is_next_to_the_tabs_file() {
        let tab = gio::File::for_path("/tmp/reports/daily.sql");

        assert_eq!(
            typed_file("weekly.sql", Some(&tab)).path(),
            Some(PathBuf::from("/tmp/reports/weekly.sql"))
        );
        assert_eq!(
            typed_file("../all.sql", Some(&tab)).path(),
            Some(PathBuf::from("/tmp/all.sql"))
        );
        assert_eq!(
            typed_file("/srv/q.sql", Some(&tab)).path(),
            Some(PathBuf::from("/srv/q.sql"))
        );
    }

    #[test]
    fn a_typed_name_next_to_a_remote_file_stays_remote() {
        let tab = gio::File::for_uri("sftp://db.example/srv/sql/daily.sql");

        assert_eq!(
            typed_file("weekly.sql", Some(&tab)).uri().as_str(),
            "sftp://db.example/srv/sql/weekly.sql"
        );
        assert_eq!(
            typed_file("sftp://db.example/all.sql", None).uri().as_str(),
            "sftp://db.example/all.sql"
        );
    }

    #[test]
    fn a_typed_name_without_a_tab_file_is_in_the_home_folder() {
        let home = glib::home_dir();

        assert_eq!(typed_file("q.sql", None).path(), Some(home.join("q.sql")));
        assert_eq!(typed_file("~/sql/q.sql", None).path(), Some(home.join("sql/q.sql")));
        assert_eq!(
            typed_file("~/q.sql", Some(&gio::File::for_path("/tmp/a.sql"))).path(),
            Some(home.join("q.sql"))
        );
    }

    #[test]
    fn an_empty_path_names_no_file() {
        assert_eq!(named(None), None);
        assert_eq!(named(Some("")), None);
        assert_eq!(named(Some("  ")), None);
        assert_eq!(named(Some(" a.sql ")), Some("a.sql"));
    }
}
