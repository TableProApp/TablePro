use std::cell::{Cell, OnceCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use sourceview5::prelude::*;

use super::find_state::FindStatus;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/find-bar.ui")]
    pub struct FindBar {
        #[template_child]
        pub search_bar: TemplateChild<gtk::SearchBar>,
        #[template_child]
        pub search_entry: TemplateChild<gtk::SearchEntry>,
        #[template_child]
        pub count_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub previous_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub next_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub options_button: TemplateChild<gtk::MenuButton>,
        #[template_child]
        pub replace_toggle: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub replace_entry: TemplateChild<gtk::Entry>,

        pub settings: sourceview5::SearchSettings,
        pub context: OnceCell<sourceview5::SearchContext>,
        pub view: glib::WeakRef<sourceview5::View>,
        pub actions: OnceCell<gio::SimpleActionGroup>,
        /// A move asked for while the search was still counting, made
        /// once it has counted.
        pub(super) pending: Cell<Option<super::Direction>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FindBar {
        const NAME: &'static str = "TableProFindBar";
        type Type = super::FindBar;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for FindBar {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![Signal::builder("toast").param_types([String::static_type()]).build()])
        }

        fn constructed(&self) {
            self.parent_constructed();
            self.obj().setup();
        }
    }

    impl WidgetImpl for FindBar {}
    impl BinImpl for FindBar {}
}

glib::wrapper! {
    /// Find and replace over an editor's buffer, through a
    /// GtkSourceSearchContext, as GNOME Text Editor lays it out.
    pub struct FindBar(ObjectSubclass<imp::FindBar>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Direction {
    Next,
    Previous,
    /// From the start of the selection, so a match being typed stays
    /// selected.
    FromSelection,
}

impl FindBar {
    fn setup(&self) {
        let imp = self.imp();
        imp.settings.set_wrap_around(true);
        imp.search_bar.connect_entry(&imp.search_entry.get());
        for (button, icon, label, action) in [
            (
                imp.previous_button.upcast_ref::<gtk::Widget>(),
                crate::ui::icons::GO_UP,
                crate::i18n::gettext("Previous Match"),
                Some("editor.find-previous"),
            ),
            (
                imp.next_button.upcast_ref(),
                crate::ui::icons::GO_DOWN,
                crate::i18n::gettext("Next Match"),
                Some("editor.find-next"),
            ),
            (
                imp.options_button.upcast_ref(),
                crate::ui::icons::VIEW_MORE,
                crate::i18n::gettext("Search Options"),
                None,
            ),
            (
                imp.replace_toggle.upcast_ref(),
                crate::ui::icons::EDIT_FIND_REPLACE,
                crate::i18n::gettext("Find and Replace"),
                Some("editor.find-replace"),
            ),
        ] {
            button.set_property("icon-name", icon);
            crate::ui::a11y::describe_icon_button(button, &label, action);
        }
        self.install_actions();

        let bar = self.downgrade();
        imp.search_entry.connect_search_changed(move |entry| {
            if let Some(bar) = bar.upgrade() {
                bar.on_search_changed(&entry.text());
            }
        });
        for (signal, direction) in [
            ("activate", Direction::Next),
            ("next-match", Direction::Next),
            ("previous-match", Direction::Previous),
        ] {
            let bar = self.downgrade();
            imp.search_entry.connect_local(signal, false, move |_| {
                if let Some(bar) = bar.upgrade() {
                    bar.find(direction);
                }
                None
            });
        }
        let bar = self.downgrade();
        imp.replace_entry.connect_activate(move |_| {
            if let Some(bar) = bar.upgrade() {
                bar.replace();
            }
        });
        // Escape in the entry ends the search through the search bar; the
        // view takes the focus back, as Text Editor's does.
        let bar = self.downgrade();
        imp.search_bar.connect_search_mode_enabled_notify(move |search_bar| {
            let Some(bar) = bar.upgrade() else {
                return;
            };
            if !search_bar.is_search_mode() {
                bar.imp().pending.set(None);
                if let Some(view) = bar.imp().view.upgrade() {
                    view.grab_focus();
                }
            }
        });
        self.refresh_status();
    }

    fn install_actions(&self) {
        let imp = self.imp();
        let actions = gio::SimpleActionGroup::new();
        for property in ["case-sensitive", "at-word-boundaries", "regex-enabled"] {
            actions.add_action(&gio::PropertyAction::new(property, &imp.settings, property));
        }
        let entry = |name: &'static str, act: fn(&FindBar)| {
            let bar = self.downgrade();
            gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
                .activate(move |_, _, _| {
                    if let Some(bar) = bar.upgrade() {
                        act(&bar);
                    }
                })
                .build()
        };
        actions.add_action_entries([
            entry("next", |bar| bar.find(Direction::Next)),
            entry("previous", |bar| bar.find(Direction::Previous)),
            entry("replace", FindBar::replace),
            entry("replace-all", FindBar::replace_all),
        ]);
        self.insert_action_group("find", Some(&actions));
        let _ = imp.actions.set(actions);
    }

    /// Search `view`'s buffer. Called once, after the buffer is set.
    pub(crate) fn attach(&self, view: &sourceview5::View) {
        let imp = self.imp();
        let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>() else {
            tracing::error!("the editor's view has no source buffer to search");
            return;
        };
        imp.view.set(Some(view));
        let context = sourceview5::SearchContext::new(&buffer, Some(&imp.settings));
        imp.search_bar
            .bind_property("search-mode-enabled", &context, "highlight")
            .sync_create()
            .build();
        let bar = self.downgrade();
        context.connect_occurrences_count_notify(move |context| {
            if let Some(bar) = bar.upgrade() {
                bar.refresh_status();
                if context.occurrences_count() >= 0
                    && let Some(direction) = bar.imp().pending.take()
                {
                    bar.move_to_match(context, direction);
                }
            }
        });
        let bar = self.downgrade();
        context.connect_regex_error_notify(move |context| {
            if let Some(bar) = bar.upgrade() {
                bar.show_regex_error(context.regex_error().as_ref());
            }
        });
        let bar = self.downgrade();
        buffer.connect_mark_set(move |buffer, _, mark| {
            let Some(bar) = bar.upgrade() else {
                return;
            };
            let moves_selection = *mark == buffer.get_insert() || *mark == buffer.selection_bound();
            if moves_selection && bar.is_open() {
                bar.refresh_status();
            }
        });
        let _ = imp.context.set(context);
    }

    pub(crate) fn is_open(&self) -> bool {
        self.imp().search_bar.is_search_mode()
    }

    /// Show the bar with the focus in its entry, taking a selection on
    /// one line as the text to find. `replace` shows the replace row too.
    pub(crate) fn open(&self, replace: bool) {
        let imp = self.imp();
        if let Some(text) = self.single_line_selection() {
            imp.search_entry.set_text(&text);
        }
        if replace {
            imp.replace_toggle.set_active(true);
        }
        imp.search_bar.set_search_mode(true);
        imp.search_entry.grab_focus();
        imp.search_entry.select_region(0, -1);
        self.refresh_status();
    }

    fn single_line_selection(&self) -> Option<String> {
        let buffer = self.imp().context.get()?.buffer();
        let (start, end) = buffer.selection_bounds()?;
        let text = buffer.text(&start, &end, false);
        (!text.contains('\n')).then(|| text.to_string())
    }

    fn on_search_changed(&self, text: &str) {
        let imp = self.imp();
        imp.settings.set_search_text((!text.is_empty()).then_some(text));
        if text.is_empty() {
            imp.pending.set(None);
            self.refresh_status();
            return;
        }
        self.find(Direction::FromSelection);
    }

    /// Select the next or previous match, wrapping at the ends.
    pub(crate) fn find(&self, direction: Direction) {
        let imp = self.imp();
        let Some(context) = imp.context.get() else {
            return;
        };
        if !self.has_search_text() {
            return;
        }
        // The sourceview5 binding of forward_async and backward_async
        // returns Ok with unset iterators when nothing matches, so the
        // move runs through the synchronous search, which says so. Once
        // the context has counted, the buffer is scanned and that search
        // only walks its match tags.
        if context.occurrences_count() < 0 {
            imp.pending.set(Some(direction));
            return;
        }
        self.move_to_match(context, direction);
    }

    fn move_to_match(&self, context: &sourceview5::SearchContext, direction: Direction) {
        let buffer = context.buffer();
        let (start, end) = selection(&buffer);
        let found = match direction {
            Direction::Next => context.forward(&end),
            Direction::Previous => context.backward(&start),
            Direction::FromSelection => context.forward(&start),
        };
        if let Some((match_start, match_end, _wrapped)) = found {
            buffer.select_range(&match_start, &match_end);
            if let Some(view) = self.imp().view.upgrade() {
                view.scroll_to_mark(&buffer.get_insert(), 0.1, false, 0.0, 0.0);
            }
        }
        self.refresh_status();
    }

    /// Replace the selected match and move to the next. A selection that
    /// is not a match is only moved from.
    pub(crate) fn replace(&self) {
        let imp = self.imp();
        let Some(context) = imp.context.get() else {
            return;
        };
        if !self.status().has_matches() {
            return;
        }
        let buffer = context.buffer();
        let (mut start, mut end) = selection(&buffer);
        if context.occurrence_position(&start, &end) <= 0 {
            self.find(Direction::Next);
            return;
        }
        if let Err(error) = context.replace(&mut start, &mut end, &imp.replace_entry.text()) {
            self.emit_by_name::<()>("toast", &[&error.message().to_owned()]);
            return;
        }
        buffer.place_cursor(&end);
        self.find(Direction::Next);
    }

    /// Replace every match, as one step Ctrl+Z takes back.
    pub(crate) fn replace_all(&self) {
        let imp = self.imp();
        let Some(context) = imp.context.get() else {
            return;
        };
        let status = self.status();
        // The binding asserts when a replace finds nothing, so it runs
        // only on a count the context has finished.
        let Some(count) = status.occurrences.filter(|_| status.has_matches()) else {
            return;
        };
        let message = match context.replace_all(&imp.replace_entry.text()) {
            Ok(()) => crate::i18n::ngettext_f(
                "Replaced {count} occurrence",
                "Replaced {count} occurrences",
                count,
                &[("count", &count.to_string())],
            ),
            Err(error) => error.message().to_owned(),
        };
        self.emit_by_name::<()>("toast", &[&message]);
        self.refresh_status();
    }

    pub(crate) fn status(&self) -> FindStatus {
        let Some(context) = self.imp().context.get() else {
            return FindStatus::default();
        };
        if !self.has_search_text() {
            return FindStatus::default();
        }
        let (start, end) = selection(&context.buffer());
        FindStatus::from_counts(
            context.occurrences_count(),
            context.occurrence_position(&start, &end),
            context.regex_error().map(|error| error.message().to_owned()),
        )
    }

    fn has_search_text(&self) -> bool {
        self.imp().settings.search_text().is_some_and(|text| !text.is_empty())
    }

    fn refresh_status(&self) {
        let imp = self.imp();
        let status = self.status();
        imp.count_label.set_label(&status.label());
        if let Some(actions) = imp.actions.get() {
            for name in ["replace", "replace-all"] {
                if let Some(action) = actions.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                    action.set_enabled(status.has_matches());
                }
            }
        }
    }

    fn show_regex_error(&self, error: Option<&glib::Error>) {
        let entry = self.imp().search_entry.get();
        match error {
            Some(error) => {
                entry.add_css_class("error");
                entry.set_tooltip_text(Some(error.message()));
            }
            None => {
                entry.remove_css_class("error");
                entry.set_tooltip_text(None);
            }
        }
        self.refresh_status();
    }

    pub(crate) fn connect_toast<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |bar: &Self, text: String| f(bar, text)),
        )
    }

    /// What the count label says.
    #[cfg(test)]
    pub(crate) fn count_text(&self) -> String {
        self.imp().count_label.label().to_string()
    }

    #[cfg(test)]
    pub(crate) fn search_entry(&self) -> gtk::SearchEntry {
        self.imp().search_entry.get()
    }

    #[cfg(test)]
    pub(crate) fn replace_entry(&self) -> gtk::Entry {
        self.imp().replace_entry.get()
    }

    #[cfg(test)]
    pub(crate) fn is_replacing(&self) -> bool {
        self.imp().replace_toggle.is_active()
    }

    #[cfg(test)]
    pub(crate) fn settings(&self) -> sourceview5::SearchSettings {
        self.imp().settings.clone()
    }

    #[cfg(test)]
    pub(crate) fn actions(&self) -> Option<gio::SimpleActionGroup> {
        self.imp().actions.get().cloned()
    }

    #[cfg(test)]
    pub(crate) fn context(&self) -> Option<sourceview5::SearchContext> {
        self.imp().context.get().cloned()
    }
}

/// The selection, or the cursor as an empty one.
fn selection(buffer: &impl IsA<gtk::TextBuffer>) -> (gtk::TextIter, gtk::TextIter) {
    let buffer = buffer.as_ref();
    buffer.selection_bounds().unwrap_or_else(|| {
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        (cursor, cursor)
    })
}
