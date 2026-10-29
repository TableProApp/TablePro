//! Recent Tabs: the window's tabs in the order they were last shown, the
//! one shown before the current first, as a list the keys walk. Ctrl+Tab
//! stays the tab view's next tab, as GNOME has it; Ctrl+E opens this list,
//! E again with Ctrl held moves down it, and letting go of Ctrl shows the
//! tab it is on.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;

use super::WorkspaceShell;
use crate::i18n::gettext;

/// The open list and the tabs it shows, in its rows' order.
pub(super) struct RecentSwitcher {
    dialog: adw::Dialog,
    list: gtk::ListBox,
    pages: Vec<adw::TabPage>,
}

impl RecentSwitcher {
    fn highlighted(&self) -> Option<usize> {
        self.list
            .selected_row()
            .and_then(|row| usize::try_from(row.index()).ok())
    }

    /// Move the highlight `by` rows, round from the last to the first.
    fn step(&self, by: isize) {
        let count = self.pages.len().cast_signed();
        let at = self.highlighted().map_or(0, usize::cast_signed);
        let next = (at + by).rem_euclid(count.max(1));
        if let Some(row) = self.list.row_at_index(i32::try_from(next).unwrap_or(0)) {
            self.list.select_row(Some(&row));
            row.grab_focus();
        }
    }
}

impl WorkspaceShell {
    /// Put the tab shown now first among the recent ones.
    pub(super) fn note_shown_tab(&self) {
        let Some(page) = self.imp().tab_view.selected_page() else {
            return;
        };
        let mut recent = self.imp().recent_tabs.borrow_mut();
        recent.retain(|held| held.upgrade().is_some_and(|held| held != page));
        recent.insert(0, page.downgrade());
    }

    /// The window's tabs, the most recently shown first. A tab never shown
    /// yet comes after them, in the tab bar's order.
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

    /// Open the list on the tab shown before this one, or move down it
    /// when it is open already.
    pub(super) fn switch_recent_tab(&self) {
        if let Some(switcher) = self.imp().recent_switcher.borrow().as_ref() {
            switcher.step(1);
            return;
        }
        let pages = self.recent_pages();
        if pages.len() < 2 {
            self.toast_overlay()
                .add_toast(crate::ui::plain_toast(&gettext("No other tab to switch to")));
            return;
        }
        let Some(window) = self.imp().window.upgrade() else {
            return;
        };
        let switcher = self.build_switcher(pages);
        switcher.dialog.present(Some(&window));
        switcher.step(1);
        self.imp().recent_switcher.replace(Some(switcher));
    }

    fn build_switcher(&self, pages: Vec<adw::TabPage>) -> RecentSwitcher {
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::Single)
            .build();
        list.add_css_class("navigation-sidebar");
        for page in &pages {
            list.append(&tab_row(page));
        }
        let scrolled = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(420)
            .child(&list)
            .build();
        let header = adw::HeaderBar::builder().show_end_title_buttons(false).build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&scrolled));
        let dialog = adw::Dialog::builder()
            .title(gettext("Recent Tabs"))
            .content_width(420)
            .child(&toolbar)
            .build();
        let shell = self.downgrade();
        list.connect_row_activated(move |_, row| {
            if let (Some(shell), Ok(at)) = (shell.upgrade(), usize::try_from(row.index())) {
                shell.show_recent(at);
            }
        });
        // Opened with Ctrl held, as Ctrl+E does, the list shows its tab
        // when Ctrl is let go; opened from a menu, it waits for Enter.
        let held = control_held(&dialog);
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let shell = self.downgrade();
        keys.connect_key_pressed(move |_, keyval, _, _| {
            let Some(shell) = shell.upgrade() else {
                return glib::Propagation::Proceed;
            };
            // Ctrl+E is the window's accelerator, which runs before this.
            let by = match keyval {
                gdk::Key::Down => 1,
                gdk::Key::Up => -1,
                _ => return glib::Propagation::Proceed,
            };
            if let Some(switcher) = shell.imp().recent_switcher.borrow().as_ref() {
                switcher.step(by);
            }
            glib::Propagation::Stop
        });
        let shell = self.downgrade();
        keys.connect_key_released(move |_, keyval, _, _| {
            if held
                && matches!(keyval, gdk::Key::Control_L | gdk::Key::Control_R)
                && let Some(shell) = shell.upgrade()
            {
                let at = shell
                    .imp()
                    .recent_switcher
                    .borrow()
                    .as_ref()
                    .and_then(RecentSwitcher::highlighted);
                if let Some(at) = at {
                    shell.show_recent(at);
                }
            }
        });
        dialog.add_controller(keys);
        let shell = self.downgrade();
        dialog.connect_closed(move |_| {
            if let Some(shell) = shell.upgrade() {
                shell.imp().recent_switcher.take();
            }
        });
        RecentSwitcher { dialog, list, pages }
    }

    /// Show the tab on row `at` and close the list.
    fn show_recent(&self, at: usize) {
        let Some(switcher) = self.imp().recent_switcher.take() else {
            return;
        };
        if let Some(page) = switcher.pages.get(at) {
            self.imp().tab_view.set_selected_page(page);
        }
        switcher.dialog.close();
    }
}

/// A tab's icon and title, as its tab shows them.
fn tab_row(page: &adw::TabPage) -> gtk::ListBoxRow {
    let content = gtk::Box::builder().spacing(12).margin_top(6).margin_bottom(6).build();
    // As its tab: an icon only where the tab has one.
    if let Some(gicon) = page.icon() {
        let icon = gtk::Image::builder()
            .gicon(&gicon)
            .accessible_role(gtk::AccessibleRole::Presentation)
            .build();
        content.append(&icon);
    }
    let title = gtk::Label::builder()
        .label(page.title())
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    content.append(&title);
    let row = gtk::ListBoxRow::builder().child(&content).build();
    row.update_property(&[gtk::accessible::Property::Label(&page.title())]);
    row
}

/// Whether Control is down on the keyboard now.
fn control_held(widget: &impl IsA<gtk::Widget>) -> bool {
    widget
        .display()
        .default_seat()
        .and_then(|seat| seat.keyboard())
        .is_some_and(|keyboard| keyboard.modifier_state().contains(gdk::ModifierType::CONTROL_MASK))
}

#[cfg(test)]
mod tests {
    use libadwaita as adw;

    use crate::test_support::drain_main_context;
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

    #[gtk4::test]
    fn the_tabs_come_most_recently_shown_first() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        let view = shell.tab_view();
        for at in [0, 2, 1] {
            view.set_selected_page(&pages[at]);
            shell.note_shown_tab();
        }
        drain_main_context();

        let titles: Vec<String> = shell
            .recent_pages()
            .iter()
            .map(|page| page.title().to_string())
            .collect();
        assert_eq!(titles, ["orders", "query", "users"]);
    }

    #[gtk4::test]
    fn a_tab_never_shown_comes_after_the_shown_ones() {
        let (shell, pages) = shell_with_tabs(&["users", "orders", "query"]);
        shell.tab_view().set_selected_page(&pages[2]);
        shell.note_shown_tab();

        let titles: Vec<String> = shell
            .recent_pages()
            .iter()
            .map(|page| page.title().to_string())
            .collect();
        assert_eq!(titles, ["query", "users", "orders"]);
    }
}
