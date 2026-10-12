use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

use super::result_item::ResultItem;
use super::run_log::{EntryKind, RunLogEntry};
use super::sidebar_policy::{self, SidebarState};

mod imp {
    use std::cell::Cell;

    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/results-pane.ui")]
    pub struct ResultsPane {
        #[template_child]
        pub sidebar_toggle: TemplateChild<gtk4::ToggleButton>,
        #[template_child]
        pub spinner: TemplateChild<adw::Spinner>,
        #[template_child]
        pub summary_label: TemplateChild<gtk4::Label>,
        #[template_child]
        pub transaction_label: TemplateChild<gtk4::Label>,
        #[template_child]
        pub split_view: TemplateChild<adw::OverlaySplitView>,
        #[template_child]
        pub list_view: TemplateChild<gtk4::ListView>,
        #[template_child]
        pub stack: TemplateChild<gtk4::Stack>,
        pub items: std::cell::OnceCell<gio::ListStore>,
        pub selection: std::cell::OnceCell<gtk4::SingleSelection>,
        pub sidebar: Cell<SidebarState>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ResultsPane {
        const NAME: &'static str = "TableProResultsPane";
        type Type = super::ResultsPane;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ResultsPane {
        fn constructed(&self) {
            self.parent_constructed();
            let pane = self.obj();
            self.sidebar_toggle.set_icon_name(crate::ui::icons::SIDEBAR_SHOW);
            // The toggle is the way back to a collapsed list, so the two
            // can never disagree about whether it shows.
            self.sidebar_toggle
                .bind_property("active", &*self.split_view, "show-sidebar")
                .bidirectional()
                .sync_create()
                .build();

            let items = gio::ListStore::new::<ResultItem>();
            let selection = gtk4::SingleSelection::new(Some(items.clone()));
            selection.set_autoselect(false);
            selection.set_can_unselect(false);
            let factory = gtk4::SignalListItemFactory::new();
            factory.connect_setup(|_, item| {
                if let Some(item) = item.downcast_ref::<gtk4::ListItem>() {
                    item.set_child(Some(&row_widget()));
                }
            });
            factory.connect_bind(|_, item| {
                if let Some(item) = item.downcast_ref::<gtk4::ListItem>() {
                    bind_row(item);
                }
            });
            self.list_view.set_factory(Some(&factory));
            self.list_view.set_model(Some(&selection));
            let weak = pane.downgrade();
            selection.connect_selected_notify(move |selection| {
                if let Some(pane) = weak.upgrade() {
                    pane.show_page(selection.selected());
                }
            });
            let _ = self.items.set(items);
            let _ = self.selection.set(selection);
        }
    }

    impl WidgetImpl for ResultsPane {}
    impl BinImpl for ResultsPane {}
}

glib::wrapper! {
    /// What a run returned: one line per statement in a list beside the
    /// result it is showing. The list folds over the result when the
    /// pane is narrow, and a toggle brings it back.
    pub struct ResultsPane(ObjectSubclass<imp::ResultsPane>)
        @extends adw::Bin, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for ResultsPane {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl ResultsPane {
    /// Forget the last run's results.
    pub fn clear(&self) {
        let imp = self.imp();
        if let Some(items) = imp.items.get() {
            items.remove_all();
        }
        let pages: Vec<gtk4::Widget> = imp
            .stack
            .pages()
            .iter::<gtk4::StackPage>()
            .filter_map(Result::ok)
            .filter(|page| page.name().is_none_or(|name| name != "empty"))
            .map(|page| page.child())
            .collect();
        for child in pages {
            imp.stack.remove(&child);
        }
        imp.stack.set_visible_child_name("empty");
        imp.sidebar.set(SidebarState::default());
        imp.sidebar_toggle.set_visible(false);
        imp.split_view.set_show_sidebar(false);
        imp.transaction_label.set_visible(false);
    }

    pub fn set_running(&self, running: bool) {
        self.imp().spinner.set_visible(running);
    }

    pub fn set_summary(&self, text: &str) {
        self.imp().summary_label.set_label(text);
    }

    pub fn set_transaction(&self, label: Option<&str>) {
        let imp = self.imp();
        imp.transaction_label.set_label(label.unwrap_or_default());
        imp.transaction_label.set_visible(label.is_some());
    }

    /// Add a line and the widget it shows.
    pub fn append(&self, entry: &RunLogEntry, widget: &gtk4::Widget) {
        let imp = self.imp();
        let Some(items) = imp.items.get() else {
            return;
        };
        let index = items.n_items();
        let (title, icon) = entry_title(index as usize, entry);
        items.append(&ResultItem::new(&title, &entry.preview, icon));
        imp.stack.add_named(widget, Some(&page_name(index)));

        let previous = SidebarState {
            show_sidebar: imp.split_view.shows_sidebar(),
            ..imp.sidebar.get()
        };
        let state = sidebar_policy::decide(items.n_items() as usize, imp.split_view.is_collapsed(), previous);
        imp.sidebar.set(state);
        imp.sidebar_toggle.set_visible(state.toggle_visible);
        imp.split_view.set_show_sidebar(state.show_sidebar);
        if index == 0 {
            self.select(0);
        }
    }

    pub fn select(&self, index: u32) {
        let Some(selection) = self.imp().selection.get() else {
            return;
        };
        if selection.selected() == index {
            self.show_page(index);
        } else {
            selection.set_selected(index);
        }
    }

    pub fn n_entries(&self) -> u32 {
        self.imp().items.get().map_or(0, gio::prelude::ListModelExt::n_items)
    }

    pub fn selected(&self) -> Option<u32> {
        let selected = self.imp().selection.get()?.selected();
        (selected != gtk4::INVALID_LIST_POSITION).then_some(selected)
    }

    fn show_page(&self, index: u32) {
        let imp = self.imp();
        if index == gtk4::INVALID_LIST_POSITION {
            return;
        }
        imp.stack.set_visible_child_name(&page_name(index));
        // A collapsed list covers the result it just picked.
        if imp.split_view.is_collapsed() {
            imp.split_view.set_show_sidebar(false);
        }
    }
}

fn page_name(index: u32) -> String {
    format!("entry-{index}")
}

/// The line's title and icon.
pub fn entry_title(index: usize, entry: &RunLogEntry) -> (String, &'static str) {
    use crate::ui::icons;
    let n = (index + 1).to_string();
    match &entry.kind {
        EntryKind::ResultSet { result, .. } => {
            let rows = result.row_count();
            (
                crate::i18n::ngettext_f(
                    "Result {n} · {rows} row",
                    "Result {n} · {rows} rows",
                    u32::try_from(rows).unwrap_or(u32::MAX),
                    &[("n", &n), ("rows", &rows.to_string())],
                ),
                icons::VIEW_GRID,
            )
        }
        EntryKind::Command {
            rows_affected: Some(rows),
        } => (
            crate::i18n::ngettext_f(
                "{n} row affected",
                "{n} rows affected",
                u32::try_from(*rows).unwrap_or(u32::MAX),
                &[("n", &rows.to_string())],
            ),
            icons::SUCCESS,
        ),
        EntryKind::Command { rows_affected: None } => (crate::i18n::gettext("Command completed"), icons::SUCCESS),
        EntryKind::Notice { .. } => (crate::i18n::gettext("Notice"), icons::TEXT_X_GENERIC),
        EntryKind::Failed { .. } => (crate::i18n::gettext("Error"), icons::DIALOG_ERROR),
        EntryKind::ClientWarning { .. } => (crate::i18n::gettext("Warning"), icons::DIALOG_WARNING),
        EntryKind::Cancelled => (crate::i18n::gettext("Stopped"), icons::PROCESS_STOP),
        EntryKind::TimedOut { .. } => (crate::i18n::gettext("Timed out"), icons::DIALOG_WARNING),
        EntryKind::NotRun => (crate::i18n::gettext("Not run"), icons::STATEMENT_PENDING),
    }
}

fn row_widget() -> gtk4::Box {
    let row = gtk4::Box::builder()
        .orientation(gtk4::Orientation::Horizontal)
        .spacing(8)
        .margin_top(4)
        .margin_bottom(4)
        .build();
    let icon = gtk4::Image::new();
    let labels = gtk4::Box::builder().orientation(gtk4::Orientation::Vertical).build();
    let title = gtk4::Label::builder()
        .xalign(0.0)
        .ellipsize(gtk4::pango::EllipsizeMode::End)
        .build();
    let subtitle = gtk4::Label::builder()
        .xalign(0.0)
        .ellipsize(gtk4::pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("dim-label");
    subtitle.add_css_class("caption");
    labels.append(&title);
    labels.append(&subtitle);
    row.append(&icon);
    row.append(&labels);
    row
}

fn bind_row(item: &gtk4::ListItem) {
    let Some(result) = item.item().and_downcast::<ResultItem>() else {
        return;
    };
    let Some(row) = item.child() else {
        return;
    };
    if let Some(icon) = row.first_child().and_downcast::<gtk4::Image>() {
        icon.set_icon_name(Some(&result.icon_name()));
    }
    let Some(labels) = row.last_child() else {
        return;
    };
    if let Some(title) = labels.first_child().and_downcast::<gtk4::Label>() {
        title.set_label(&result.title());
    }
    if let Some(subtitle) = labels.last_child().and_downcast::<gtk4::Label>() {
        let preview = result.subtitle();
        subtitle.set_visible(!preview.is_empty());
        subtitle.set_label(&preview);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane() -> ResultsPane {
        crate::register_test_resources();
        ResultsPane::default()
    }

    fn entry(kind: EntryKind) -> RunLogEntry {
        RunLogEntry {
            kind,
            batch: Some(0),
            preview: "SELECT 1".to_owned(),
        }
    }

    fn command() -> RunLogEntry {
        entry(EntryKind::Command { rows_affected: Some(1) })
    }

    fn page() -> gtk4::Widget {
        gtk4::Label::new(Some("page")).upcast()
    }

    #[gtk4::test]
    fn twenty_results_use_list_not_switcher() {
        let pane = pane();

        for _ in 0..20 {
            pane.append(&command(), &page());
        }

        let imp = pane.imp();
        assert_eq!(pane.n_entries(), 20);
        assert!(imp.sidebar_toggle.is_visible());
        assert!(imp.split_view.shows_sidebar(), "the list stayed closed on a wide pane");
        assert_eq!(imp.stack.visible_child_name().as_deref(), Some("entry-0"));
    }

    #[gtk4::test]
    fn a_single_result_has_no_list() {
        let pane = pane();

        pane.append(&command(), &page());

        assert!(!pane.imp().sidebar_toggle.is_visible());
        assert!(!pane.imp().split_view.shows_sidebar());
    }

    #[gtk4::test]
    fn first_failure_is_selected() {
        let pane = pane();
        pane.append(&command(), &page());
        pane.append(
            &entry(EntryKind::Failed {
                message: "boom".to_owned(),
                error_char: None,
            }),
            &page(),
        );
        pane.append(&entry(EntryKind::NotRun), &page());

        pane.select(1);

        assert_eq!(pane.selected(), Some(1));
        assert_eq!(pane.imp().stack.visible_child_name().as_deref(), Some("entry-1"));
    }

    #[gtk4::test]
    fn collapsed_selection_hides_sidebar_and_toggle_reopens_list() {
        let pane = pane();
        let imp = pane.imp();
        imp.split_view.set_collapsed(true);
        for _ in 0..3 {
            pane.append(&command(), &page());
        }
        imp.split_view.set_show_sidebar(true);

        pane.select(2);
        assert!(
            !imp.split_view.shows_sidebar(),
            "the list stayed over the picked result"
        );
        assert!(!imp.sidebar_toggle.is_active());

        imp.sidebar_toggle.set_active(true);
        assert!(imp.split_view.shows_sidebar(), "the toggle did not bring the list back");
    }

    #[gtk4::test]
    fn clearing_forgets_the_last_run() {
        let pane = pane();
        pane.append(&command(), &page());
        pane.append(&command(), &page());

        pane.clear();

        assert_eq!(pane.n_entries(), 0);
        assert!(!pane.imp().sidebar_toggle.is_visible());
        assert_eq!(pane.imp().stack.visible_child_name().as_deref(), Some("empty"));
        pane.append(&command(), &page());
        assert_eq!(pane.imp().stack.visible_child_name().as_deref(), Some("entry-0"));
    }

    #[gtk4::test]
    fn the_list_toggle_has_an_accessible_name() {
        let pane = pane();

        assert!(gtk4::test_accessible_has_property(
            &pane.imp().sidebar_toggle.get(),
            gtk4::AccessibleProperty::Label
        ));
    }
}
