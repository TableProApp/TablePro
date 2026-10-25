use std::cell::Cell;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;

use super::browse_pager::BrowsePager;
use super::page_label::page_range_label;
use super::page_state::PageState;
use super::row_total::RowTotal;
use crate::i18n::gettext;
use crate::ui::a11y::{announce_key_shortcuts, describe_icon_button};

/// What a click in the bar asks the tab for, one signal each.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PagerRequest {
    First,
    Previous,
    Next,
    Last,
    CountRows,
}

impl PagerRequest {
    const ALL: [Self; 5] = [Self::First, Self::Previous, Self::Next, Self::Last, Self::CountRows];

    fn signal(self) -> &'static str {
        match self {
            Self::First => "first",
            Self::Previous => "previous",
            Self::Next => "next",
            Self::Last => "last",
            Self::CountRows => "count-rows",
        }
    }
}

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate, glib::Properties)]
    #[properties(wrapper_type = super::PagerBar)]
    #[template(resource = "/app/tablepro/TablePro/ui/pager-bar.ui")]
    pub struct PagerBar {
        #[template_child]
        pub first_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub prev_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub next_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub last_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub paginator_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub count_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub count_spinner: TemplateChild<adw::Spinner>,
        #[template_child]
        pub count_label: TemplateChild<gtk::Label>,
        /// Below the tab's breakpoint, Count Rows is in the tab's More
        /// menu instead.
        #[property(get, set = Self::set_compact)]
        compact: Cell<bool>,
        count_offered: Cell<bool>,
    }

    impl PagerBar {
        fn set_compact(&self, compact: bool) {
            self.compact.set(compact);
            self.show_count_button();
        }

        pub(super) fn offer_count(&self, offered: bool) {
            self.count_offered.set(offered);
            self.show_count_button();
        }

        fn show_count_button(&self) {
            self.count_button
                .set_visible(self.count_offered.get() && !self.compact.get());
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for PagerBar {
        const NAME: &'static str = "TableProPagerBar";
        type Type = super::PagerBar;
        type ParentType = gtk::Box;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    #[glib::derived_properties]
    impl ObjectImpl for PagerBar {
        fn constructed(&self) {
            self.parent_constructed();
            let bar = self.obj();
            bar.describe_buttons();
            bar.connect_buttons();
        }

        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                PagerRequest::ALL
                    .into_iter()
                    .map(|request| Signal::builder(request.signal()).build())
                    .collect()
            })
        }
    }

    impl WidgetImpl for PagerBar {}
    impl BoxImpl for PagerBar {}
}

glib::wrapper! {
    /// The browse tab's pager: First, Previous, Next and Last, the rows
    /// on the page, and Count Rows. It shows what the tab tells it and
    /// sends each click back as a signal.
    pub struct PagerBar(ObjectSubclass<imp::PagerBar>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}

impl Default for PagerBar {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl PagerBar {
    pub(super) fn connect_request<F: Fn(&Self) + 'static>(&self, request: PagerRequest, f: F) -> glib::SignalHandlerId {
        self.connect_closure(request.signal(), false, glib::closure_local!(move |bar: &Self| f(bar)))
    }

    /// A page turn moves the pager before its read lands, so a failed
    /// read leaves the pager on a page the grid does not show. The way
    /// back goes from the pager, and Next waits for a page on screen.
    pub(super) fn show_position(&self, pager: &BrowsePager, rows_on_page: u64) {
        let imp = self.imp();
        self.turn(&[
            (imp.first_button.get(), pager.first().is_some()),
            (imp.prev_button.get(), pager.prev().is_some()),
            (imp.next_button.get(), pager.next(rows_on_page).is_some()),
        ]);
    }

    /// Turn each button on or off. The focus on a button turned off goes
    /// to the nearest one left on, as Next at the last page hands it to
    /// Previous; GTK would move it to the window's first control.
    fn turn(&self, changes: &[(gtk::Button, bool)]) {
        for (button, _) in changes.iter().filter(|(_, on)| *on) {
            button.set_sensitive(true);
        }
        let usable = |button: &gtk::Button| {
            changes
                .iter()
                .find(|(changed, _)| changed == button)
                .map_or(button.is_sensitive(), |(_, on)| *on)
                && button.is_visible()
        };
        let buttons = self.buttons();
        if let Some(from) = buttons
            .iter()
            .position(|button| crate::ui::a11y::holds_focus(button) && !usable(button))
        {
            let nearest = (1..buttons.len())
                .flat_map(|distance| [from.checked_sub(distance), Some(from + distance)])
                .flatten()
                .filter_map(|index| buttons.get(index))
                .find(|button| usable(button));
            if let Some(nearest) = nearest {
                nearest.grab_focus();
            }
        }
        for (button, _) in changes.iter().filter(|(_, on)| !*on) {
            button.set_sensitive(false);
        }
    }

    /// The bar's buttons in the order they sit.
    fn buttons(&self) -> [gtk::Button; 5] {
        let imp = self.imp();
        [
            imp.first_button.get(),
            imp.prev_button.get(),
            imp.next_button.get(),
            imp.last_button.get(),
            imp.count_button.get(),
        ]
    }

    /// The rows on the page, Count Rows and Last, which only an exact
    /// total enables.
    pub(super) fn show_total(&self, pager: &BrowsePager, shown: Option<&PageState>, total: &RowTotal) {
        let imp = self.imp();
        let label = shown.map(|page| page_range_label(page, total)).unwrap_or_default();
        crate::ui::a11y::show_status(&imp.paginator_label, &label);
        let last_tooltip = match total.exact() {
            Some(_) => gettext("Last Page"),
            None => gettext("Count rows to go to the last page"),
        };
        imp.last_button.set_tooltip_text(Some(&last_tooltip));

        let counting = matches!(total, RowTotal::Counting { .. });
        let count_offered = shown.is_some() && total.exact().is_none();
        if count_offered {
            imp.offer_count(true);
        }
        self.turn(&[
            (imp.last_button.get(), pager.last(total).is_some()),
            (imp.count_button.get(), count_offered && !counting),
        ]);
        imp.offer_count(count_offered);
        imp.count_spinner.set_visible(counting);
        let (label, reason) = match total {
            RowTotal::Counting { .. } => (gettext("Counting…"), None),
            RowTotal::Unavailable { reason, .. } => (gettext("Try Again"), Some(reason.as_str())),
            RowTotal::Unknown | RowTotal::Estimated(_) | RowTotal::Exact(_) => (gettext("Count Rows"), None),
        };
        imp.count_label.set_label(&label);
        self.show_count_failure(reason);
    }

    /// A count asked for and refused says why, on Try Again as well as
    /// in its tooltip, which no key shows.
    fn show_count_failure(&self, reason: Option<&str>) {
        let button = self.imp().count_button.get();
        let news = reason.is_some() && button.tooltip_text().as_deref() != reason;
        button.set_tooltip_text(reason);
        let widget = button.upcast_ref::<gtk::Widget>();
        match reason {
            Some(reason) => widget.update_property(&[gtk::accessible::Property::Description(reason)]),
            None => widget.reset_property(gtk::AccessibleProperty::Description),
        }
        if let Some(reason) = reason.filter(|_| news) {
            crate::ui::a11y::announce(
                &button,
                &crate::i18n::gettext_f("Couldn't count the rows. {reason}", &[("reason", reason)]),
                gtk::AccessibleAnnouncementPriority::High,
            );
        }
    }

    /// The keys for Previous and Next turn a page only where the button
    /// would, so the tab's actions follow the buttons, and the buttons
    /// announce the actions' keys.
    pub(super) fn follow_page_actions(&self, group: &str, previous: &gio::SimpleAction, next: &gio::SimpleAction) {
        let imp = self.imp();
        for (button, action) in [(&imp.prev_button, previous), (&imp.next_button, next)] {
            button
                .bind_property("sensitive", action, "enabled")
                .sync_create()
                .build();
            announce_key_shortcuts(&button.get(), &format!("{group}.{}", action.name()));
        }
    }

    fn describe_buttons(&self) {
        let imp = self.imp();
        for (button, label) in [
            (&imp.first_button, gettext("First Page")),
            (&imp.prev_button, gettext("Previous Page")),
            (&imp.next_button, gettext("Next Page")),
            (&imp.last_button, gettext("Last Page")),
        ] {
            describe_icon_button(&button.get(), &label, None);
        }
    }

    fn connect_buttons(&self) {
        let imp = self.imp();
        for (button, request) in [
            (&imp.first_button, PagerRequest::First),
            (&imp.prev_button, PagerRequest::Previous),
            (&imp.next_button, PagerRequest::Next),
            (&imp.last_button, PagerRequest::Last),
            (&imp.count_button, PagerRequest::CountRows),
        ] {
            let bar = self.downgrade();
            button.connect_clicked(move |_| {
                if let Some(bar) = bar.upgrade() {
                    bar.emit_by_name::<()>(request.signal(), &[]);
                }
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4::AccessibleProperty;

    use super::*;
    use crate::test_support::SignalLog;

    fn bar() -> PagerBar {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        PagerBar::default()
    }

    fn page(start_ordinal: u64, row_count: usize) -> PageState {
        PageState {
            row_count,
            start_ordinal,
            filtered: false,
        }
    }

    #[gtk4::test]
    fn first_and_previous_insensitive_at_start() {
        let bar = bar();
        let imp = bar.imp();

        bar.show_position(&BrowsePager::new(100, 0), 100);

        assert!(!imp.first_button.is_sensitive());
        assert!(!imp.prev_button.is_sensitive());
        assert!(imp.next_button.is_sensitive(), "a full page has a next one");

        bar.show_position(&BrowsePager::new(100, 200), 40);

        assert!(imp.first_button.is_sensitive());
        assert!(imp.prev_button.is_sensitive());
        assert!(!imp.next_button.is_sensitive(), "a short page was the last one");
    }

    #[gtk4::test]
    fn page_actions_follow_the_buttons_and_announce_their_keys() {
        let bar = bar();
        let imp = bar.imp();
        let previous = gio::SimpleAction::new("previous-page", None);
        let next = gio::SimpleAction::new("next-page", None);
        assert!(!gtk::test_accessible_has_property(
            &imp.next_button.get(),
            AccessibleProperty::KeyShortcuts
        ));

        bar.follow_page_actions("browse", &previous, &next);
        bar.show_position(&BrowsePager::new(100, 0), 100);

        assert!(!previous.is_enabled(), "Previous turned a page before the first");
        assert!(next.is_enabled());
        for button in [imp.prev_button.get(), imp.next_button.get()] {
            assert!(
                gtk::test_accessible_has_property(&button, AccessibleProperty::KeyShortcuts),
                "{:?} announces no keys",
                button.tooltip_text()
            );
        }

        bar.show_position(&BrowsePager::new(100, 200), 40);

        assert!(previous.is_enabled());
        assert!(!next.is_enabled(), "Next turned past the last page");
    }

    #[gtk4::test]
    fn next_click_emits_next() {
        let bar = bar();
        let next = SignalLog::connect(&bar, "next", |_| ());
        let previous = SignalLog::connect(&bar, "previous", |_| ());
        bar.show_position(&BrowsePager::new(100, 0), 100);

        bar.imp().next_button.emit_clicked();

        assert_eq!(next.count(), 1);
        assert_eq!(previous.count(), 0);
    }

    #[gtk4::test]
    fn last_insensitive_until_total_is_exact() {
        let bar = bar();
        let last = bar.imp().last_button.get();
        let pager = BrowsePager::new(100, 0);
        let shown = page(0, 100);

        bar.show_total(&pager, Some(&shown), &RowTotal::Estimated(5_000));

        assert!(!last.is_sensitive());
        assert_eq!(
            last.tooltip_text().as_deref(),
            Some("Count rows to go to the last page")
        );

        bar.show_total(&pager, Some(&shown), &RowTotal::Exact(5_000));

        assert!(last.is_sensitive());
        assert_eq!(last.tooltip_text().as_deref(), Some("Last Page"));
        assert!(!bar.imp().count_button.is_visible(), "an exact total offers no count");
    }

    #[gtk4::test]
    fn count_rows_click_emits_count_rows() {
        let bar = bar();
        let counts = SignalLog::connect(&bar, "count-rows", |_| ());
        bar.show_total(&BrowsePager::new(100, 0), Some(&page(0, 100)), &RowTotal::Unknown);
        let imp = bar.imp();
        assert!(imp.count_button.is_visible() && imp.count_button.is_sensitive());
        assert_eq!(imp.count_label.label(), "Count Rows");

        imp.count_button.emit_clicked();

        assert_eq!(counts.count(), 1);
    }

    /// The bar in a window, so its buttons can hold the focus.
    fn shown_bar() -> (PagerBar, crate::test_support::OwnedWindow<gtk::Window>) {
        let bar = bar();
        let window = crate::test_support::OwnedWindow::presented(gtk::Window::builder().child(&bar).build());
        (bar, window)
    }

    fn focus(window: &gtk::Window) -> Option<gtk::Widget> {
        gtk::prelude::GtkWindowExt::focus(window)
    }

    #[gtk4::test]
    fn next_at_the_last_page_hands_the_focus_to_previous() {
        let (bar, window) = shown_bar();
        let imp = bar.imp();
        bar.show_position(&BrowsePager::new(100, 0), 100);
        assert!(imp.next_button.grab_focus());

        bar.show_position(&BrowsePager::new(100, 100), 40);

        assert!(!imp.next_button.is_sensitive());
        assert_eq!(focus(&window).as_ref(), Some(imp.prev_button.upcast_ref()));
    }

    #[gtk4::test]
    fn a_count_keeps_the_focus_in_the_bar() {
        let (bar, window) = shown_bar();
        let imp = bar.imp();
        let pager = BrowsePager::new(100, 0);
        let shown = page(0, 100);
        bar.show_position(&pager, 100);
        bar.show_total(&pager, Some(&shown), &RowTotal::Estimated(5_000));
        assert!(imp.count_button.grab_focus());

        bar.show_total(&pager, Some(&shown), &RowTotal::Counting { estimate: Some(5_000) });
        assert_eq!(focus(&window).as_ref(), Some(imp.next_button.upcast_ref()));

        let refused = RowTotal::Unavailable {
            estimate: Some(5_000),
            reason: "refused".to_owned(),
        };
        bar.show_total(&pager, Some(&shown), &refused);
        assert!(imp.count_button.grab_focus());
        bar.show_total(&pager, Some(&shown), &RowTotal::Exact(5_000));
        assert!(!imp.count_button.is_visible());
        assert_eq!(focus(&window).as_ref(), Some(imp.last_button.upcast_ref()));
    }

    #[gtk4::test]
    fn a_failed_count_says_why_on_try_again() {
        let bar = bar();
        let pager = BrowsePager::new(100, 0);
        let failed = RowTotal::Unavailable {
            estimate: None,
            reason: "Counting took longer than 45 seconds and was stopped.".to_owned(),
        };

        bar.show_total(&pager, Some(&page(0, 100)), &failed);

        let button = bar.imp().count_button.get();
        assert!(gtk::test_accessible_has_property(
            &button,
            AccessibleProperty::Description
        ));
        assert_eq!(
            crate::ui::a11y::announced_in(&bar)
                .last()
                .map(|(said, priority)| (said.clone(), *priority)),
            Some((
                "Couldn't count the rows. Counting took longer than 45 seconds and was stopped.".to_owned(),
                gtk::AccessibleAnnouncementPriority::High
            ))
        );

        bar.show_total(&pager, Some(&page(0, 100)), &RowTotal::Exact(500));

        assert!(!gtk::test_accessible_has_property(
            &button,
            AccessibleProperty::Description
        ));
    }

    #[gtk4::test]
    fn a_compact_bar_leaves_count_rows_to_the_menu() {
        let bar = bar();
        let count = bar.imp().count_button.get();
        bar.show_total(&BrowsePager::new(100, 0), Some(&page(0, 100)), &RowTotal::Unknown);

        bar.set_compact(true);
        assert!(!count.is_visible());
        bar.show_total(&BrowsePager::new(100, 0), Some(&page(0, 100)), &RowTotal::Unknown);
        assert!(!count.is_visible(), "a new total put Count Rows back on a compact bar");

        bar.set_compact(false);
        assert!(count.is_visible());
    }

    #[gtk4::test]
    fn the_range_label_waits_for_a_page_on_screen() {
        let bar = bar();
        let pager = BrowsePager::new(100, 0);

        bar.show_total(&pager, None, &RowTotal::Exact(5));

        assert_eq!(bar.imp().paginator_label.label(), "");
        assert!(!bar.imp().count_button.is_visible());

        bar.show_total(&pager, Some(&page(0, 5)), &RowTotal::Exact(5));

        assert_eq!(bar.imp().paginator_label.label(), "Rows 1 – 5 of 5");
        assert_eq!(
            crate::ui::a11y::announced_in(&bar),
            [(
                "Rows 1 – 5 of 5".to_owned(),
                gtk::AccessibleAnnouncementPriority::Medium
            )],
            "a page turn is said once"
        );
    }
}
