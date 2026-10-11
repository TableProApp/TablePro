use relm4::gtk;
use relm4::gtk::prelude::*;
use sourceview5::prelude::*;

const MAX_PREFILL_BYTES: usize = 200;

pub struct FindBar {
    bar: gtk::SearchBar,
    entry: gtk::SearchEntry,
    replace_entry: gtk::Entry,
    view: sourceview5::View,
    context: sourceview5::SearchContext,
    count: gtk::Label,
    match_case: gtk::ToggleButton,
    regex: gtk::ToggleButton,
}

pub fn match_label(position: i32, count: i32) -> String {
    match (position, count) {
        (_, count) if count < 0 => String::new(),
        (_, 0) => crate::tr!("No results"),
        (position, count) if position > 0 => crate::tr!("{position} of {count}")
            .replace("{position}", &position.to_string())
            .replace("{count}", &count.to_string()),
        (_, count) => crate::tr!("{count} results").replace("{count}", &count.to_string()),
    }
}

fn prefill_text(selection: &str) -> Option<&str> {
    (!selection.is_empty() && !selection.contains('\n') && selection.len() <= MAX_PREFILL_BYTES).then_some(selection)
}

impl FindBar {
    pub fn new(view: &sourceview5::View) -> Option<Self> {
        let buffer = view.buffer().downcast::<sourceview5::Buffer>().ok()?;
        let settings = sourceview5::SearchSettings::new();
        settings.set_wrap_around(true);
        let context = sourceview5::SearchContext::new(&buffer, Some(&settings));
        context.set_highlight(false);

        let entry = gtk::SearchEntry::builder()
            .hexpand(true)
            .placeholder_text(crate::tr!("Find"))
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Find"))]);
        let previous = flat_button("go-up-symbolic", &crate::tr!("Previous match"));
        let next = flat_button("go-down-symbolic", &crate::tr!("Next match"));
        let count = gtk::Label::builder().xalign(1.0).width_chars(12).build();
        count.add_css_class("dim-label");
        let (match_case, regex) = search_option_toggles();
        let replace_toggle = gtk::ToggleButton::builder()
            .icon_name("edit-find-replace-symbolic")
            .tooltip_text(crate::tr!("Replace"))
            .build();
        replace_toggle.add_css_class("flat");

        let find_row = row_of(&[
            entry.upcast_ref::<gtk::Widget>(),
            previous.upcast_ref(),
            next.upcast_ref(),
            count.upcast_ref(),
            match_case.upcast_ref(),
            regex.upcast_ref(),
            replace_toggle.upcast_ref(),
        ]);

        let (replace_row, replace_entry, replace_one, replace_all) = replace_controls();
        replace_toggle
            .bind_property("active", &replace_row, "visible")
            .sync_create()
            .build();

        let bar = search_bar(&find_row, &replace_row, &entry);

        let find = Self {
            bar,
            entry,
            replace_entry,
            view: view.clone(),
            context,
            count,
            match_case,
            regex,
        };
        find.connect(&settings, &previous, &next, &replace_one, &replace_all);
        find.connect_search_options(&settings);
        Some(find)
    }

    pub fn widget(&self) -> &gtk::SearchBar {
        &self.bar
    }

    pub fn open(&self) {
        let buffer = self.view.buffer();
        if let Some((start, end)) = buffer.selection_bounds()
            && let Some(text) = prefill_text(buffer.text(&start, &end, false).as_str())
        {
            self.entry.set_text(text);
        }
        self.bar.set_search_mode(true);
        self.entry.select_region(0, -1);
        self.entry.grab_focus();
    }

    fn connect(
        &self,
        settings: &sourceview5::SearchSettings,
        previous: &gtk::Button,
        next: &gtk::Button,
        replace_one: &gtk::Button,
        replace_all: &gtk::Button,
    ) {
        let this = self.handle();
        let settings = settings.clone();
        let entry = self.entry.clone();
        let handle = this.clone();
        self.entry.connect_search_changed(move |_| {
            let text = entry.text();
            settings.set_search_text((!text.is_empty()).then_some(text.as_str()));
            handle.step(true, true);
        });
        let handle = this.clone();
        self.entry.connect_activate(move |_| handle.step(true, false));
        let handle = this.clone();
        self.entry.connect_next_match(move |_| handle.step(true, false));
        let handle = this.clone();
        self.entry.connect_previous_match(move |_| handle.step(false, false));
        let handle = this.clone();
        next.connect_clicked(move |_| handle.step(true, false));
        let handle = this.clone();
        previous.connect_clicked(move |_| handle.step(false, false));
        let handle = this.clone();
        replace_one.connect_clicked(move |_| handle.replace_current());
        let handle = this.clone();
        replace_all.connect_clicked(move |_| handle.replace_all());
        let handle = this.clone();
        self.context
            .connect_occurrences_count_notify(move |_| handle.refresh_count());
        let handle = this;
        self.bar.connect_search_mode_enabled_notify(move |bar| {
            let open = bar.is_search_mode();
            handle.context.set_highlight(open);
            if !open {
                handle.view.grab_focus();
            }
        });
    }

    fn connect_search_options(&self, settings: &sourceview5::SearchSettings) {
        let handle = self.handle();
        let case_settings = settings.clone();
        let case_handle = handle.clone();
        self.match_case.connect_toggled(move |toggle| {
            case_settings.set_case_sensitive(toggle.is_active());
            case_handle.step(true, true);
        });
        let regex_settings = settings.clone();
        self.regex.connect_toggled(move |toggle| {
            regex_settings.set_regex_enabled(toggle.is_active());
            handle.step(true, true);
        });
    }

    fn handle(&self) -> FindHandle {
        FindHandle {
            view: self.view.clone(),
            context: self.context.clone(),
            replace_entry: self.replace_entry.clone(),
            count: self.count.clone(),
        }
    }
}

#[derive(Clone)]
struct FindHandle {
    view: sourceview5::View,
    context: sourceview5::SearchContext,
    replace_entry: gtk::Entry,
    count: gtk::Label,
}

impl FindHandle {
    fn step(&self, forward: bool, from_selection_start: bool) {
        let buffer = self.view.buffer();
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        let (start, end) = buffer.selection_bounds().unwrap_or((cursor, cursor));
        let found = match (forward, from_selection_start) {
            (true, true) => self.context.forward(&start),
            (true, false) => self.context.forward(&end),
            (false, _) => self.context.backward(&start),
        };
        if let Some((match_start, match_end, _)) = found {
            buffer.select_range(&match_start, &match_end);
            self.view.scroll_to_mark(&buffer.get_insert(), 0.1, false, 0.0, 0.0);
        }
        self.refresh_count();
    }

    fn replace_current(&self) {
        let buffer = self.view.buffer();
        let Some((mut start, mut end)) = buffer.selection_bounds() else {
            self.step(true, false);
            return;
        };
        if self.context.occurrence_position(&start, &end) <= 0 {
            self.step(true, false);
            return;
        }
        if self
            .context
            .replace(&mut start, &mut end, self.replace_entry.text().as_str())
            .is_ok()
        {
            self.step(true, false);
        }
    }

    fn replace_all(&self) {
        let _ = self.context.replace_all(self.replace_entry.text().as_str());
        self.refresh_count();
    }

    fn refresh_count(&self) {
        let buffer = self.view.buffer();
        let position = buffer
            .selection_bounds()
            .map(|(start, end)| self.context.occurrence_position(&start, &end))
            .unwrap_or(0);
        self.count
            .set_text(&match_label(position, self.context.occurrences_count()));
    }
}

fn replace_controls() -> (gtk::Box, gtk::Entry, gtk::Button, gtk::Button) {
    let entry = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(crate::tr!("Replace with"))
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Replace with"))]);
    let replace_one = gtk::Button::with_label(&crate::tr!("Replace"));
    let replace_all = gtk::Button::with_label(&crate::tr!("Replace All"));
    let row = row_of(&[entry.upcast_ref(), replace_one.upcast_ref(), replace_all.upcast_ref()]);
    (row, entry, replace_one, replace_all)
}

fn row_of(widgets: &[&gtk::Widget]) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    for widget in widgets {
        row.append(*widget);
    }
    row
}

fn search_bar(find_row: &gtk::Box, replace_row: &gtk::Box, entry: &gtk::SearchEntry) -> gtk::SearchBar {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
    column.set_margin_top(6);
    column.set_margin_bottom(6);
    column.set_margin_start(8);
    column.set_margin_end(8);
    column.append(find_row);
    column.append(replace_row);
    let bar = gtk::SearchBar::new();
    bar.set_child(Some(&column));
    bar.connect_entry(entry);
    bar
}

fn search_option_toggles() -> (gtk::ToggleButton, gtk::ToggleButton) {
    (
        flat_toggle("Aa", &crate::tr!("Match case")),
        flat_toggle(".*", &crate::tr!("Regular expression")),
    )
}

fn flat_toggle(label: &str, tooltip: &str) -> gtk::ToggleButton {
    let toggle = gtk::ToggleButton::builder().label(label).tooltip_text(tooltip).build();
    toggle.add_css_class("flat");
    toggle
}

fn flat_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::builder().icon_name(icon).tooltip_text(tooltip).build();
    button.add_css_class("flat");
    button
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_label_reports_position_total_or_nothing_found() {
        assert_eq!(match_label(-1, -1), "");
        assert_eq!(match_label(0, 0), "No results");
        assert_eq!(match_label(3, 12), "3 of 12");
        assert_eq!(match_label(0, 12), "12 results");
    }

    #[test]
    fn only_a_short_single_line_selection_prefills_the_search() {
        assert_eq!(prefill_text("users"), Some("users"));
        assert_eq!(prefill_text(""), None);
        assert_eq!(prefill_text("a\nb"), None);
        assert_eq!(prefill_text(&"x".repeat(MAX_PREFILL_BYTES + 1)), None);
    }

    fn settle(context: &sourceview5::SearchContext) {
        let main = gtk::glib::MainContext::default();
        for _ in 0..200 {
            if context.occurrences_count() >= 0 {
                return;
            }
            main.iteration(false);
        }
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn find_selects_matches_and_replace_all_rewrites_every_occurrence() {
        gtk::init().unwrap();
        sourceview5::init();
        let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
        buffer.set_text("select a, a from t where a = 1");
        let view = sourceview5::View::with_buffer(&buffer);
        let find = FindBar::new(&view).unwrap();

        find.entry.set_text("a");
        find.entry.emit_by_name::<()>("search-changed", &[]);
        settle(&find.context);
        assert_eq!(find.context.occurrences_count(), 3);
        assert_eq!(find.count.text(), "1 of 3");

        find.handle().step(true, false);
        assert_eq!(find.count.text(), "2 of 3");

        buffer.set_text("Aa aA");
        find.entry.set_text("a");
        find.entry.emit_by_name::<()>("search-changed", &[]);
        settle(&find.context);
        assert_eq!(find.context.occurrences_count(), 4);
        find.match_case.set_active(true);
        settle(&find.context);
        assert_eq!(find.context.occurrences_count(), 2);
        find.regex.set_active(true);
        find.entry.set_text("[aA]+");
        find.entry.emit_by_name::<()>("search-changed", &[]);
        settle(&find.context);
        assert_eq!(find.context.occurrences_count(), 2);
        find.match_case.set_active(false);
        find.regex.set_active(false);
        buffer.set_text("select a, a from t where a = 1");
        find.entry.set_text("a");
        find.entry.emit_by_name::<()>("search-changed", &[]);
        settle(&find.context);

        find.replace_entry.set_text("b");
        find.handle().replace_all();
        let (start, end) = buffer.bounds();
        assert_eq!(buffer.text(&start, &end, false), "select b, b from t where b = 1");
    }
}
