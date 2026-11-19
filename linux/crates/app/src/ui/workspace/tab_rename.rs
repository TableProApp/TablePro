use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib};
use libadwaita as adw;

use super::{WorkspaceInput, WorkspaceShell};
use crate::i18n::gettext;
use crate::runtime::DeliverInput;
use crate::ui::editor::SqlEditor;

pub(super) const RENAME_TAB: &str = "rename-tab";

// libadwaita keeps its tab widgets private, so they are found by type name: docs/toolkit-workarounds.md,
// "Renaming a tab from the tab bar".
const BAR_TAB: &str = "AdwTab";
const OVERVIEW_TAB: &str = "AdwTabThumbnail";

pub(super) struct RenameSeed {
    pub(super) shown: String,
    pub(super) automatic: String,
}

// Kept, hidden, until the next rename, the shell's shutdown or its dispose unparents it: unparenting inside
// `closed` would free the popover while GtkPopover still uses it.
pub(super) struct RenameEdit {
    page: glib::WeakRef<adw::TabPage>,
    popover: gtk::Popover,
    cancelled: Rc<Cell<bool>>,
}

impl RenameEdit {
    pub(super) fn release(self) {
        self.cancelled.set(true);
        self.popover.popdown();
        if self.popover.parent().is_some() {
            self.popover.unparent();
        }
    }
}

impl WorkspaceShell {
    pub(super) fn connect_rename(&self) {
        let imp = self.imp();
        let shell = self.downgrade();
        imp.tab_view.connect_n_pages_notify(move |_| {
            if let Some(shell) = shell.upgrade() {
                shell.refresh_rename_action();
            }
        });
        imp.tab_bar.add_controller(rename_on_double_click(self));
    }

    pub(super) fn can_rename(&self, page: &adw::TabPage) -> bool {
        self.tab_view().n_pages() >= 2
            && self.owner_of(page).is_some()
            && page
                .child()
                .downcast_ref::<SqlEditor>()
                .is_some_and(|editor| editor.file().is_none())
    }

    // F2 goes on to the focused widget's other handlers while the tab in front cannot be renamed.
    pub(super) fn refresh_rename_action(&self) {
        let enabled = self
            .tab_view()
            .selected_page()
            .is_some_and(|page| self.can_rename(&page));
        if let Some(action) = self
            .imp()
            .window
            .upgrade()
            .and_then(|window| window.lookup_action(RENAME_TAB))
            .and_downcast::<gio::SimpleAction>()
        {
            action.set_enabled(enabled);
        }
    }

    pub(super) fn start_rename(&self, page: &adw::TabPage) {
        if self.renaming(page) || !self.can_rename(page) {
            return;
        }
        let Some((owner, id)) = self.owner_of(page) else {
            return;
        };
        let (Some(seed), Some(input)) = (owner.read(|model| model.rename_seed(id)).flatten(), owner.sender()) else {
            return;
        };
        // One field at a time, and opening another commits the first as moving the focus away does.
        self.end_rename(false);
        let (anchor, pointing) = self.rename_anchor(page);
        let (popover, cancelled) = rename_popover(&seed, move |text| {
            input.deliver(WorkspaceInput::RenameTab { id, text });
        });
        let shell = self.downgrade();
        let renamed = page.downgrade();
        popover.connect_closed(move |_| {
            let (shell, renamed) = (shell.clone(), renamed.clone());
            // GtkPopover hands the focus to its parent after `closed`, and the user goes on in the editor.
            glib::idle_add_local_once(move || {
                if let (Some(shell), Some(page)) = (shell.upgrade(), renamed.upgrade()) {
                    shell.focus_after_rename(&page);
                }
            });
        });
        popover.set_parent(&anchor);
        popover.set_pointing_to(pointing.as_ref());
        self.imp().rename.replace(Some(RenameEdit {
            page: page.downgrade(),
            popover: popover.clone(),
            cancelled,
        }));
        popover.popup();
    }

    pub(super) fn cancel_rename_of(&self, page: &adw::TabPage) {
        if self.renaming(page) {
            self.end_rename(true);
        }
    }

    pub(super) fn end_rename(&self, cancel: bool) {
        let open = self
            .imp()
            .rename
            .borrow()
            .as_ref()
            .map(|edit| (edit.popover.clone(), edit.cancelled.clone()));
        if let Some((popover, cancelled)) = open {
            if cancel {
                cancelled.set(true);
            }
            popover.popdown();
        }
        if let Some(edit) = self.imp().rename.take() {
            edit.release();
        }
    }

    fn renaming(&self, page: &adw::TabPage) -> bool {
        self.imp()
            .rename
            .borrow()
            .as_ref()
            .is_some_and(|edit| edit.popover.is_visible() && edit.page.upgrade().as_ref() == Some(page))
    }

    fn focus_after_rename(&self, page: &adw::TabPage) {
        let imp = self.imp();
        let editing = imp
            .rename
            .borrow()
            .as_ref()
            .is_some_and(|edit| edit.popover.is_visible());
        if editing || imp.tab_overview.is_open() || self.tab_view().selected_page().as_ref() != Some(page) {
            return;
        }
        if let Ok(editor) = page.child().downcast::<SqlEditor>() {
            editor.focus_text();
        }
    }

    // The bar hides with one tab and on a narrow window, and the overview covers it while open.
    fn rename_anchor(&self, page: &adw::TabPage) -> (gtk::Widget, Option<gdk::Rectangle>) {
        let imp = self.imp();
        let overview: gtk::Widget = imp.tab_overview.get().upcast();
        if imp.tab_overview.is_open() {
            let content = imp.tab_overview.child();
            if let Some(thumbnail) = tab_widget(&overview, OVERVIEW_TAB, page, content.as_ref()) {
                return (overview.clone(), rect_in(&thumbnail, &overview));
            }
            return (overview, None);
        }
        let bar: gtk::Widget = imp.tab_bar.get().upcast();
        if imp.tab_bar.is_mapped()
            && imp.tab_bar.is_tabs_revealed()
            && let Some(tab) = tab_widget(&bar, BAR_TAB, page, None)
        {
            return (bar.clone(), rect_in(&tab, &bar));
        }
        let title: gtk::Widget = imp.window_title.get().upcast();
        if title.is_mapped() {
            return (title, None);
        }
        (overview, None)
    }
}

fn rename_popover(seed: &RenameSeed, commit: impl Fn(String) + 'static) -> (gtk::Popover, Rc<Cell<bool>>) {
    let entry = gtk::Entry::builder()
        .text(seed.shown.as_str())
        .placeholder_text(seed.automatic.as_str())
        .width_chars(24)
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(&gettext("Tab Name"))]);
    let popover = gtk::Popover::builder()
        .child(&entry)
        .position(gtk::PositionType::Bottom)
        .build();
    let edited = Rc::new(Cell::new(false));
    let cancelled = Rc::new(Cell::new(false));
    let finished = Rc::new(Cell::new(false));

    // A change event, not a comparison: Return on an untouched `Query 3` must not keep it as a typed name.
    let (typed, resumed) = (edited.clone(), cancelled.clone());
    entry.connect_changed(move |_| {
        typed.set(true);
        resumed.set(false);
    });

    let finish: Rc<dyn Fn(&gtk::Entry)> = {
        let (edited, finished) = (edited, finished);
        Rc::new(move |entry: &gtk::Entry| {
            if !finished.replace(true) && edited.get() {
                commit(entry.text().to_string());
            }
        })
    };

    let (on_return, shown) = (finish.clone(), popover.downgrade());
    entry.connect_activate(move |entry| {
        on_return(entry);
        if let Some(popover) = shown.upgrade() {
            popover.popdown();
        }
    });

    // Every way the popover hides emits the same `closed`, so Escape is told apart before GtkPopover sees it.
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let escaped = cancelled.clone();
    keys.connect_key_pressed(move |_, keyval, _, _| {
        if keyval == gdk::Key::Escape {
            escaped.set(true);
        }
        glib::Propagation::Proceed
    });
    popover.add_controller(keys);

    let (on_close, field, dropped) = (finish, entry.downgrade(), cancelled.clone());
    popover.connect_closed(move |_| {
        if !dropped.get()
            && let Some(entry) = field.upgrade()
        {
            on_close(&entry);
        }
    });

    let select = entry.downgrade();
    popover.connect_show(move |_| {
        if let Some(entry) = select.upgrade() {
            entry.grab_focus();
            entry.select_region(0, -1);
        }
    });
    (popover, cancelled)
}

fn rename_on_double_click(shell: &WorkspaceShell) -> gtk::GestureClick {
    let click = gtk::GestureClick::new();
    click.set_button(gdk::BUTTON_PRIMARY);
    // Before the tab box, which selects on the first press and never reports the second.
    click.set_propagation_phase(gtk::PropagationPhase::Capture);
    let first: Rc<RefCell<Option<glib::WeakRef<adw::TabPage>>>> = Rc::default();
    let pressed = first.clone();
    click.connect_pressed(move |gesture, presses, x, y| {
        if presses == 1 {
            let page = gesture.widget().and_then(|bar| page_at(&bar, x, y));
            pressed.replace(page.map(|page| page.downgrade()));
        }
    });
    let shell = shell.downgrade();
    click.connect_released(move |gesture, presses, x, y| {
        if presses != 2 {
            return;
        }
        let first = first.take().and_then(|page| page.upgrade());
        let Some(page) = gesture.widget().and_then(|bar| page_at(&bar, x, y)) else {
            return;
        };
        // A fast double-click on Close must not rename the tab that slid under the pointer.
        if first.as_ref() != Some(&page) || !shell.upgrade().is_some_and(|shell| shell.can_rename(&page)) {
            return;
        }
        let shell = shell.clone();
        glib::idle_add_local_once(move || {
            if let Some(shell) = shell.upgrade() {
                shell.start_rename(&page);
            }
        });
    });
    click
}

fn page_at(bar: &gtk::Widget, x: f64, y: f64) -> Option<adw::TabPage> {
    let mut widget = bar.pick(x, y, gtk::PickFlags::DEFAULT)?;
    loop {
        // libadwaita leaves a press on a tab's close or indicator button to the button.
        if widget.is::<gtk::Button>() || &widget == bar {
            return None;
        }
        if widget.type_().name() == BAR_TAB {
            return page_of(&widget);
        }
        widget = widget.parent()?;
    }
}

fn page_of(widget: &gtk::Widget) -> Option<adw::TabPage> {
    widget
        .find_property("page")
        .filter(|spec| spec.value_type() == adw::TabPage::static_type())
        .and_then(|_| widget.property::<Option<adw::TabPage>>("page"))
}

fn tab_widget(
    root: &gtk::Widget,
    type_name: &str,
    page: &adw::TabPage,
    skip: Option<&gtk::Widget>,
) -> Option<gtk::Widget> {
    let mut pending: Vec<gtk::Widget> = root.first_child().into_iter().collect();
    while let Some(widget) = pending.pop() {
        if let Some(sibling) = widget.next_sibling() {
            pending.push(sibling);
        }
        if Some(&widget) == skip {
            continue;
        }
        if widget.type_().name() == type_name {
            if widget.is_mapped() && page_of(&widget).as_ref() == Some(page) {
                return Some(widget);
            }
            continue;
        }
        if let Some(child) = widget.first_child() {
            pending.push(child);
        }
    }
    None
}

// A tab scrolled partly out of the bar is pointed at where it shows.
fn rect_in(widget: &gtk::Widget, parent: &gtk::Widget) -> Option<gdk::Rectangle> {
    let bounds = widget.compute_bounds(parent)?;
    let rect = gdk::Rectangle::new(
        bounds.x() as i32,
        bounds.y() as i32,
        bounds.width() as i32,
        bounds.height() as i32,
    );
    let shown = gdk::Rectangle::new(0, 0, parent.width(), parent.height());
    Some(rect.intersect(&shown).unwrap_or(rect))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{assert_labelled, drain_main_context, finish_on_main, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};
    use crate::ui::workspace::tests::{open_editor, shell_of, two_sessions};
    use crate::ui::workspace::{Workspace, WorkspaceTab};

    fn field(shell: &WorkspaceShell) -> Option<(gtk::Popover, gtk::Entry)> {
        let popover = shell.imp().rename.borrow().as_ref().map(|edit| edit.popover.clone())?;
        let entry = popover.child().and_downcast::<gtk::Entry>()?;
        Some((popover, entry))
    }

    fn open_field(shell: &WorkspaceShell, page: &adw::TabPage) -> (gtk::Popover, gtk::Entry) {
        shell.start_rename(page);
        let (popover, entry) = field(shell).expect("the rename field");
        assert!(popover.is_visible(), "the field did not open");
        (popover, entry)
    }

    fn typed_name(workspace: &Workspace, page: &adw::TabPage) -> Option<String> {
        let id = workspace.tab_id(page)?;
        workspace
            .read(|model| match model.workspace_tabs.borrow().get(&id) {
                Some(WorkspaceTab::Editor(slot)) => slot.name.clone(),
                _ => None,
            })
            .flatten()
    }

    #[gtk4::test]
    fn return_commits_what_was_typed_and_an_untouched_field_commits_nothing() {
        let test = TestWindow::connected("RenameReturn");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let page = open_editor(&workspace);
        open_editor(&workspace);

        let (popover, entry) = open_field(&shell, &page);
        assert_eq!(entry.text(), "Query 1");
        assert_eq!(entry.placeholder_text().as_deref(), Some("Query 1"));
        assert_eq!(entry.selection_bounds(), Some((0, 7)), "the title is not selected");
        assert_labelled(&entry).unwrap_or_else(|problem| panic!("{problem:?}"));
        entry.emit_activate();
        assert!(!popover.is_visible(), "Return left the field open");
        drain_main_context();
        assert_eq!(
            typed_name(&workspace, &page),
            None,
            "Return on an untouched field kept the automatic title as a name"
        );

        let (_, entry) = open_field(&shell, &page);
        entry.set_text("Q");
        entry.set_text("Query 1");
        entry.emit_activate();
        wait_until(WAIT, || typed_name(&workspace, &page).as_deref() == Some("Query 1"))
            .expect("a retyped title to count as a name");

        let (_, entry) = open_field(&shell, &page);
        assert_eq!(entry.text(), "Query 1");
        entry.set_text("Revenue");
        entry.emit_activate();
        wait_until(WAIT, || page.title() == "Revenue").expect("the typed name");
    }

    #[gtk4::test]
    fn the_field_commits_when_it_closes_any_other_way_and_one_field_shows_at_a_time() {
        let test = TestWindow::connected("RenameFocusLoss");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let first = open_editor(&workspace);
        let second = open_editor(&workspace);

        let (first_field, entry) = open_field(&shell, &first);
        entry.set_text("One");
        let (second_field, entry) = open_field(&shell, &second);

        assert!(!first_field.is_visible(), "two fields are open");
        wait_until(WAIT, || first.title() == "One").expect("opening another field to commit the first");
        assert!(first_field.parent().is_none(), "the closed field stayed in the bar");
        entry.set_text("Two");
        // What a click outside an autohide popover does.
        second_field.popdown();
        wait_until(WAIT, || second.title() == "Two").expect("the field closing to commit");
    }

    #[gtk4::test]
    fn escape_recorded_before_the_popover_closes_cancels() {
        let test = TestWindow::connected("RenameEscape");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let page = open_editor(&workspace);
        open_editor(&workspace);
        let (popover, entry) = open_field(&shell, &page);
        entry.set_text("Dropped");
        let controllers = popover.observe_controllers();
        let keys = (0..controllers.n_items())
            .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
            .find(|controller| controller.propagation_phase() == gtk::PropagationPhase::Capture)
            .expect("the field's Escape watch");

        keys.emit_by_name::<bool>("key-pressed", &[&gdk::Key::Escape, &0u32, &gdk::ModifierType::empty()]);
        popover.popdown();
        drain_main_context();

        assert_eq!(typed_name(&workspace, &page), None);
        assert_eq!(page.title(), "Query 1");
    }

    #[gtk4::test]
    fn closing_the_tab_or_binding_it_to_a_file_drops_its_field() {
        let test = TestWindow::connected("RenameTabGoes");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let view = shell.tab_view();
        let closing = open_editor(&workspace);
        let filed = open_editor(&workspace);
        open_editor(&workspace);

        let (popover, entry) = open_field(&shell, &closing);
        entry.set_text("Gone");
        view.close_page(&closing);
        wait_until(WAIT, || !popover.is_visible()).expect("the field to go with its tab");

        let (popover, entry) = open_field(&shell, &filed);
        entry.set_text("Ledger");
        let path = test.dir().join("daily.sql");
        crate::test_support::write_text_file(&path, "SELECT 1;");
        let editor = filed.child().downcast::<SqlEditor>().expect("an editor tab");
        finish_on_main(WAIT, async move {
            editor.insert_file(gio::File::for_path(&path), true).await
        })
        .expect("the file to load");

        wait_until(WAIT, || !popover.is_visible()).expect("the field to go once the file names the tab");
        wait_until(WAIT, || filed.title() == "daily.sql").expect("the file's name");
        assert_eq!(typed_name(&workspace, &filed), None);
    }

    #[gtk4::test]
    fn a_tab_that_cannot_take_a_name_opens_no_field() {
        let test = TestWindow::connected("RenameRefused");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let only = open_editor(&workspace);

        shell.start_rename(&only);

        assert!(field(&shell).is_none(), "a tab alone in the window opened a field");
    }

    #[gtk4::test]
    fn the_field_points_at_the_tab_in_the_bar_or_in_the_open_overview() {
        let test = TestWindow::connected("RenameAnchor");
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let page = open_editor(&workspace);
        open_editor(&workspace);
        let bar: gtk::Widget = shell.imp().tab_bar.get().upcast();
        wait_until(WAIT, || tab_widget(&bar, BAR_TAB, &page, None).is_some()).expect("the tab in the bar");

        let (popover, entry) = open_field(&shell, &page);

        assert_eq!(popover.parent().as_ref(), Some(&bar));
        let (pointed, rect) = popover.pointing_to();
        assert!(pointed && rect.width() > 0 && rect.height() > 0, "{rect:?}");
        entry.emit_activate();

        let overview = shell.imp().tab_overview.get();
        overview.set_open(true);
        let content = overview.child();
        wait_until(WAIT, || {
            tab_widget(overview.upcast_ref(), OVERVIEW_TAB, &page, content.as_ref()).is_some()
        })
        .expect("the tab in the overview");
        let (popover, _) = open_field(&shell, &page);
        assert_eq!(popover.parent().as_ref(), Some(overview.upcast_ref::<gtk::Widget>()));
        assert!(popover.pointing_to().0, "the field points at the whole overview");
    }

    #[gtk4::test]
    fn the_field_renames_the_tab_in_the_session_that_owns_it() {
        let sessions = two_sessions("RenameOwner", "Other");
        let ours = open_editor(&sessions.first);
        let theirs = open_editor(&sessions.second);

        let (_, entry) = open_field(&sessions.shell, &theirs);
        entry.set_text("Revenue");
        entry.emit_activate();

        wait_until(WAIT, || theirs.title() == "Revenue (Other)").expect("the other session's tab renamed");
        assert_eq!(typed_name(&sessions.second, &theirs).as_deref(), Some("Revenue"));
        assert_eq!(typed_name(&sessions.first, &ours), None);
    }

    // These press real keys on the X display every test shares, so nextest runs them alone.
    mod real_keys {
        use gtk4 as gtk;
        use gtk4::gdk;
        use gtk4::prelude::*;
        use gtk4::subclass::prelude::*;

        use super::super::{BAR_TAB, tab_widget};
        use super::field;
        use crate::test_support::{KeyInjector, drain_main_context, wait_until};
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::ui::workspace::tests::{open_editor, shell_of};

        #[gtk4::test]
        fn a_double_click_on_a_tab_renames_it_and_escape_leaves_it_as_it_was() {
            let test = TestWindow::connected("RenameDoubleClick");
            let workspace = test.workspace();
            let shell = shell_of(&workspace);
            let page = open_editor(&workspace);
            open_editor(&workspace);
            KeyInjector::focus_only(&test.window);
            wait_until(WAIT, || test.window.is_active()).expect("the window to take the focus");
            let keys = KeyInjector::connect().expect("an X11 display");
            let bar: gtk::Widget = shell.imp().tab_bar.get().upcast();
            wait_until(WAIT, || tab_widget(&bar, BAR_TAB, &page, None).is_some()).expect("the tab in the bar");
            let tab = tab_widget(&bar, BAR_TAB, &page, None).expect("the tab in the bar");
            let middle = (tab.width() as f32 / 2.0, tab.height() as f32 / 2.0);
            let field_open = || field(&shell).is_some_and(|(popover, _)| popover.is_visible());

            keys.click(&tab, middle, 2).expect("the double-click");
            wait_until(WAIT, field_open).expect("a double-click to open the field");
            for key in [gdk::Key::a, gdk::Key::b, gdk::Key::c] {
                keys.press(key, gdk::ModifierType::empty()).expect("the key press");
            }
            keys.press(gdk::Key::Return, gdk::ModifierType::empty())
                .expect("Return");
            wait_until(WAIT, || page.title() == "abc").expect("Return to commit the typed name");
            assert!(!field_open(), "Return left the field open");

            keys.click(&tab, middle, 2).expect("the double-click");
            wait_until(WAIT, field_open).expect("the field again");
            keys.press(gdk::Key::x, gdk::ModifierType::empty())
                .expect("the key press");
            keys.press(gdk::Key::Escape, gdk::ModifierType::empty())
                .expect("Escape");
            wait_until(WAIT, || !field_open()).expect("Escape to close the field");
            drain_main_context();

            assert_eq!(page.title(), "abc", "Escape kept what was typed");
        }

        #[gtk4::test]
        fn f2_renames_the_query_tab_in_front() {
            let test = TestWindow::connected("RenameF2");
            let workspace = test.workspace();
            let shell = shell_of(&workspace);
            open_editor(&workspace);
            let page = open_editor(&workspace);
            KeyInjector::focus_only(&test.window);
            wait_until(WAIT, || test.window.is_active()).expect("the window to take the focus");
            let keys = KeyInjector::connect().expect("an X11 display");

            keys.press(gdk::Key::F2, gdk::ModifierType::empty()).expect("F2");

            wait_until(WAIT, || field(&shell).is_some_and(|(popover, _)| popover.is_visible()))
                .expect("F2 to open the field");
            let (_, entry) = field(&shell).expect("the field");
            assert_eq!(entry.text(), "Query 2", "F2 opened the field on another tab");
            keys.press(gdk::Key::z, gdk::ModifierType::empty())
                .expect("the key press");
            keys.press(gdk::Key::Return, gdk::ModifierType::empty())
                .expect("Return");
            wait_until(WAIT, || page.title() == "z").expect("the typed name");
        }
    }
}
