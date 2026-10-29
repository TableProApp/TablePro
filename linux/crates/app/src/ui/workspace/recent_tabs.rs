//! Ctrl+E walks back through the tabs in the order they were shown, the
//! tab bar showing where it is. Ctrl+Tab stays the next tab, as in GNOME.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use libadwaita as adw;

use super::WorkspaceShell;

const WALK_KEYS: &str = "tablepro-recent-walk-keys";
const SWITCH_RECENT_TAB: &str = "win.switch-recent-tab";

pub(super) struct RecentWalk {
    // Frozen at the first press, so the tabs it passes do not reorder it.
    order: Vec<glib::WeakRef<adw::TabPage>>,
    at: usize,
}

impl RecentWalk {
    fn step(&mut self, view: &adw::TabView) -> Option<adw::TabPage> {
        let count = self.order.len();
        (1..count).find_map(|offset| {
            let at = (self.at + offset) % count;
            let page = self.order[at].upgrade().filter(|page| holds(view, page))?;
            self.at = at;
            Some(page)
        })
    }

    fn start(&self, view: &adw::TabView) -> Option<adw::TabPage> {
        self.order
            .first()
            .and_then(glib::WeakRef::upgrade)
            .filter(|page| holds(view, page))
    }
}

pub(super) struct WalkHooks {
    window: glib::WeakRef<adw::ApplicationWindow>,
    keys: gtk::EventControllerKey,
    active: glib::SignalHandlerId,
}

impl WalkHooks {
    pub(super) fn release(self) {
        if let Some(window) = self.window.upgrade() {
            window.remove_controller(&self.keys);
            window.disconnect(self.active);
        }
    }
}

impl WorkspaceShell {
    pub(super) fn note_shown_tab(&self) {
        let imp = self.imp();
        // A walk records only the tab it ends on.
        if imp.recent_walk.borrow().is_some() {
            return;
        }
        let Some(page) = imp.tab_view.selected_page() else {
            return;
        };
        let mut recent = imp.recent_tabs.borrow_mut();
        recent.retain(|held| held.upgrade().is_some_and(|held| held != page));
        recent.insert(0, page.downgrade());
    }

    pub(super) fn recent_pages(&self) -> Vec<adw::TabPage> {
        let view = self.imp().tab_view.get();
        let open: Vec<adw::TabPage> = (0..view.n_pages()).map(|at| view.nth_page(at)).collect();
        let mut pages: Vec<adw::TabPage> = self
            .imp()
            .recent_tabs
            .borrow()
            .iter()
            .filter_map(glib::WeakRef::upgrade)
            .filter(|page| open.contains(page))
            .collect();
        for page in open {
            if !pages.contains(&page) {
                pages.push(page);
            }
        }
        pages
    }

    pub(super) fn switch_recent_tab(&self) {
        let imp = self.imp();
        if imp.recent_walk.borrow().is_none() {
            let order = self.recent_pages().iter().map(ObjectExt::downgrade).collect();
            imp.recent_walk.replace(Some(RecentWalk { order, at: 0 }));
        }
        let view = imp.tab_view.get();
        let next = imp
            .recent_walk
            .borrow_mut()
            .as_mut()
            .and_then(|walk| walk.step(&view));
        if let Some(page) = next {
            view.set_selected_page(&page);
        }
        // No release to wait for, as GNOME Shell's switcher checks.
        if !control_held(&view) {
            self.end_recent_walk(true);
        }
    }

    pub(super) fn end_recent_walk(&self, keep: bool) {
        let Some(walk) = self.imp().recent_walk.take() else {
            return;
        };
        let view = self.imp().tab_view.get();
        if !keep && let Some(start) = walk.start(&view) {
            view.set_selected_page(&start);
        }
        self.note_shown_tab();
    }

    pub(super) fn hook_recent_walk(&self, window: &adw::ApplicationWindow) -> WalkHooks {
        // On the window and past the event boundary of a dialog or a
        // popover, so the release reaches it wherever the focus is.
        let keys = gtk::EventControllerKey::new();
        keys.set_name(Some(WALK_KEYS));
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        keys.set_propagation_limit(gtk::PropagationLimit::None);
        let shell = self.downgrade();
        keys.connect_key_pressed(move |controller, keyval, _, state| {
            let Some(shell) = shell.upgrade() else {
                return glib::Propagation::Proceed;
            };
            let walking = shell.imp().recent_walk.borrow().is_some();
            if !walking {
                return glib::Propagation::Proceed;
            }
            if keyval == gdk::Key::Escape {
                shell.end_recent_walk(false);
                return glib::Propagation::Stop;
            }
            let modifier = controller
                .current_event()
                .and_then(|event| event.downcast::<gdk::KeyEvent>().ok())
                .is_some_and(|event| event.is_modifier());
            // This controller runs before the window's accelerators, so
            // another command acts on the tab the walk reached.
            if !modifier && !crate::application::component_matches(SWITCH_RECENT_TAB, keyval, state) {
                shell.end_recent_walk(true);
            }
            glib::Propagation::Proceed
        });
        let shell = self.downgrade();
        keys.connect_key_released(move |_, keyval, _, _| {
            if matches!(keyval, gdk::Key::Control_L | gdk::Key::Control_R)
                && let Some(shell) = shell.upgrade()
            {
                shell.end_recent_walk(true);
            }
        });
        window.add_controller(keys.clone());
        // The release goes to another window once this one loses the keyboard.
        let shell = self.downgrade();
        let active = window.connect_is_active_notify(move |window| {
            if !window.is_active()
                && let Some(shell) = shell.upgrade()
            {
                shell.end_recent_walk(true);
            }
        });
        WalkHooks {
            window: window.downgrade(),
            keys,
            active,
        }
    }
}

fn holds(view: &adw::TabView, page: &adw::TabPage) -> bool {
    (0..view.n_pages()).any(|at| &view.nth_page(at) == page)
}

fn control_held(widget: &impl IsA<gtk::Widget>) -> bool {
    widget
        .display()
        .default_seat()
        .and_then(|seat| seat.keyboard())
        .is_some_and(|keyboard| keyboard.modifier_state().contains(gdk::ModifierType::CONTROL_MASK))
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::subclass::prelude::*;
    use libadwaita as adw;

    use crate::ui::workspace::WorkspaceShell;

    fn shell_with_tabs(titles: &[&str]) -> (WorkspaceShell, Vec<adw::TabPage>) {
        crate::register_test_resources();
        let shell: WorkspaceShell = gtk4::glib::Object::new();
        let view = shell.tab_view();
        let pages = titles
            .iter()
            .map(|title| {
                let page = view.append(&gtk4::Label::new(Some(title)));
                page.set_title(title);
                page
            })
            .collect();
        (shell, pages)
    }

    fn titles(pages: &[adw::TabPage]) -> Vec<String> {
        pages.iter().map(|page| page.title().to_string()).collect()
    }

    fn selected(shell: &WorkspaceShell) -> String {
        shell
            .tab_view()
            .selected_page()
            .map(|page| page.title().to_string())
            .unwrap_or_default()
    }

    fn show(shell: &WorkspaceShell, pages: &[adw::TabPage], order: &[usize]) {
        for at in order {
            shell.tab_view().set_selected_page(&pages[*at]);
            shell.note_shown_tab();
        }
    }

    #[gtk4::test]
    fn the_tabs_come_most_recently_shown_first() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[0, 2, 1]);

        assert_eq!(titles(&shell.recent_pages()), ["orders", "query", "users"]);
    }

    #[gtk4::test]
    fn a_tab_never_shown_comes_after_the_shown_ones() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[2]);

        assert_eq!(titles(&shell.recent_pages()), ["query", "users", "orders"]);
    }

    #[gtk4::test]
    fn a_closed_tab_leaves_the_order() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[0, 1, 2]);

        shell.tab_view().close_page(&pages[1]);

        assert_eq!(titles(&shell.recent_pages()), ["query", "users"]);
    }

    #[gtk4::test]
    fn without_ctrl_held_each_switch_goes_to_the_tab_shown_before() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[0, 1, 2]);

        shell.switch_recent_tab();
        assert_eq!(selected(&shell), "orders");
        assert!(shell.imp().recent_walk.borrow().is_none(), "a walk waits for a release");
        shell.switch_recent_tab();
        assert_eq!(selected(&shell), "query");
        assert_eq!(titles(&shell.recent_pages()), ["query", "orders", "users"]);
    }

    #[gtk4::test]
    fn a_walk_records_only_the_tab_it_ends_on() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[0, 1, 2]);
        let imp = shell.imp();
        imp.recent_walk.replace(Some(super::RecentWalk {
            order: shell.recent_pages().iter().map(ObjectExt::downgrade).collect(),
            at: 0,
        }));

        for _ in 0..2 {
            let next = imp
                .recent_walk
                .borrow_mut()
                .as_mut()
                .and_then(|walk| walk.step(&shell.tab_view()));
            shell.tab_view().set_selected_page(&next.expect("a tab to go to"));
            shell.note_shown_tab();
        }
        assert_eq!(selected(&shell), "users");
        assert_eq!(titles(&shell.recent_pages()), ["query", "orders", "users"]);

        shell.end_recent_walk(true);
        assert_eq!(titles(&shell.recent_pages()), ["users", "query", "orders"]);
    }

    #[gtk4::test]
    fn a_walk_skips_a_tab_closed_on_the_way_and_escape_returns_to_the_start() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        show(&shell, &pages, &[0, 1, 2]);
        let imp = shell.imp();
        imp.recent_walk.replace(Some(super::RecentWalk {
            order: shell.recent_pages().iter().map(ObjectExt::downgrade).collect(),
            at: 0,
        }));
        shell.tab_view().close_page(&pages[1]);

        let next = imp
            .recent_walk
            .borrow_mut()
            .as_mut()
            .and_then(|walk| walk.step(&shell.tab_view()));
        assert_eq!(next.as_ref(), Some(&pages[0]), "the walk went to a closed tab");
        shell.tab_view().set_selected_page(&pages[0]);

        shell.end_recent_walk(false);
        assert_eq!(selected(&shell), "query");
        assert_eq!(titles(&shell.recent_pages()), ["query", "users"]);
    }

    #[gtk4::test]
    fn the_window_lets_go_of_the_walk_keys_with_the_shell() {
        use crate::ui::SessionWindowInput;
        use crate::ui::session_window::tests::TestWindow;
        let test = TestWindow::connected("RecentWalkKeys");
        let walk_keys = || {
            let controllers = test.window.observe_controllers();
            (0..controllers.n_items())
                .filter_map(|at| controllers.item(at).and_downcast::<gtk4::EventController>())
                .filter(|controller| controller.name().as_deref() == Some(super::WALK_KEYS))
                .count()
        };
        assert_eq!(walk_keys(), 1);

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");

        assert_eq!(walk_keys(), 0, "the picker kept the walk's keys");
    }

    /// These press real keys on the X display every test shares; nextest
    /// runs them with no other test beside them.
    mod real_keys {
        use gtk4::gdk;
        use gtk4::prelude::*;
        use gtk4::subclass::prelude::*;
        use libadwaita as adw;
        use libadwaita::prelude::*;

        use crate::test_support::{KeyInjector, wait_until};
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::ui::workspace::WorkspaceShell;
        use crate::ui::workspace::tests::{open_editor, shell_of};

        struct Walking {
            test: TestWindow,
            shell: WorkspaceShell,
            pages: Vec<adw::TabPage>,
            keys: KeyInjector,
        }

        /// Three editor tabs, opened and so shown in order: the recent
        /// order is the third, the second, the first.
        fn walking(name: &str) -> Walking {
            let test = TestWindow::connected(name);
            let workspace = test.workspace();
            let shell = shell_of(&workspace);
            let pages: Vec<adw::TabPage> = (0..3).map(|_| open_editor(&workspace)).collect();
            assert_eq!(shell.recent_pages(), [pages[2].clone(), pages[1].clone(), pages[0].clone()]);
            KeyInjector::focus_only(&test.window);
            wait_until(WAIT, || test.window.is_active()).expect("the window to take the focus");
            let keys = KeyInjector::connect().expect("an X11 display");
            Walking {
                test,
                shell,
                pages,
                keys,
            }
        }

        impl Walking {
            fn selected(&self) -> Option<adw::TabPage> {
                self.shell.tab_view().selected_page()
            }

            fn wait_for(&self, page: usize, what: &str) {
                wait_until(WAIT, || self.selected().as_ref() == Some(&self.pages[page])).expect(what);
            }

            fn press_e(&self) {
                self.keys
                    .press(gdk::Key::e, gdk::ModifierType::empty())
                    .expect("the key press");
            }

            fn is_walking(&self) -> bool {
                self.shell.imp().recent_walk.borrow().is_some()
            }
        }

        #[gtk4::test]
        fn holding_ctrl_walks_back_and_letting_go_keeps_the_tab() {
            let walk = walking("RecentWalkKeep");
            {
                let _ctrl = walk.keys.hold(gdk::Key::Control_L).expect("Ctrl held");
                wait_until(WAIT, || super::super::control_held(&walk.test.window)).expect("GDK to see Ctrl down");
                walk.press_e();
                walk.wait_for(1, "Ctrl+E to show the tab shown before");
                walk.press_e();
                walk.wait_for(0, "E again to go one further back");
                assert!(walk.is_walking(), "the walk ended with Ctrl still held");
            }
            wait_until(WAIT, || !walk.is_walking()).expect("letting go of Ctrl to end the walk");

            assert_eq!(walk.selected().as_ref(), Some(&walk.pages[0]));
            let order = [walk.pages[0].clone(), walk.pages[2].clone(), walk.pages[1].clone()];
            assert_eq!(walk.shell.recent_pages(), order, "the tabs passed on the way were recorded");

            walk.keys
                .press(gdk::Key::e, gdk::ModifierType::CONTROL_MASK)
                .expect("the key press");
            walk.wait_for(2, "a tap of Ctrl+E to go back to the tab before");
        }

        #[gtk4::test]
        fn another_command_ends_the_walk_on_the_tab_it_reached() {
            let walk = walking("RecentWalkCommand");
            let workspace = walk.test.workspace();
            {
                let _ctrl = walk.keys.hold(gdk::Key::Control_L).expect("Ctrl held");
                wait_until(WAIT, || super::super::control_held(&walk.test.window)).expect("GDK to see Ctrl down");
                walk.press_e();
                walk.wait_for(1, "Ctrl+E to show the tab shown before");
                walk.keys
                    .press(gdk::Key::t, gdk::ModifierType::empty())
                    .expect("the key press");
                wait_until(WAIT, || workspace.imp().index.get().map_or(0, |index| index.pages().len()) == 4)
                    .expect("Ctrl+T to open a tab");
                assert!(!walk.is_walking(), "the walk went on past Ctrl+T");
            }

            let new = walk.selected().expect("the new tab in front");
            assert!(!walk.pages.contains(&new));
            let order = [new, walk.pages[1].clone(), walk.pages[2].clone(), walk.pages[0].clone()];
            assert_eq!(walk.shell.recent_pages(), order, "the tab the walk reached was not recorded");
        }

        #[gtk4::test]
        fn letting_go_of_ctrl_in_a_dialog_ends_the_walk() {
            let walk = walking("RecentWalkDialog");
            let dialog = adw::AlertDialog::new(Some("Connection Lost"), None);
            dialog.add_response("close", "Close");
            {
                let _ctrl = walk.keys.hold(gdk::Key::Control_L).expect("Ctrl held");
                wait_until(WAIT, || super::super::control_held(&walk.test.window)).expect("GDK to see Ctrl down");
                walk.press_e();
                walk.wait_for(1, "Ctrl+E to show the tab shown before");
                dialog.present(Some(&walk.test.window));
                wait_until(WAIT, || {
                    gtk4::prelude::RootExt::focus(&walk.test.window).is_some_and(|focus| focus.is_ancestor(&dialog))
                })
                .expect("the dialog to take the focus");
            }
            wait_until(WAIT, || !walk.is_walking()).expect("letting go of Ctrl in the dialog to end the walk");

            let order = [walk.pages[1].clone(), walk.pages[2].clone(), walk.pages[0].clone()];
            assert_eq!(walk.shell.recent_pages(), order);
            dialog.close();
        }

        #[gtk4::test]
        fn escape_ends_a_walk_on_the_tab_it_started_on() {
            let walk = walking("RecentWalkEscape");
            {
                let _ctrl = walk.keys.hold(gdk::Key::Control_L).expect("Ctrl held");
                wait_until(WAIT, || super::super::control_held(&walk.test.window)).expect("GDK to see Ctrl down");
                walk.press_e();
                walk.wait_for(1, "Ctrl+E to show the tab shown before");
                walk.keys
                    .press(gdk::Key::Escape, gdk::ModifierType::empty())
                    .expect("the key press");
                walk.wait_for(2, "Escape to go back to the start");
                assert!(!walk.is_walking(), "Escape left the walk on");
            }

            let order = [walk.pages[2].clone(), walk.pages[1].clone(), walk.pages[0].clone()];
            assert_eq!(walk.shell.recent_pages(), order);
        }
    }
}
