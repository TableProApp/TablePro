//! The shell's chrome: the header bars, the sidebar, the breakpoints and
//! the window floor, the overview and the main menu.

use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::{served_table, shell_of};
use crate::test_support::{descendants, wait_until};
use crate::ui::SessionWindowInput;
use crate::ui::session_window::tests::{Script, TestWindow, WAIT};
use crate::ui::workspace::{WorkspaceShell, WorkspaceTab};

fn overview_new_tab_button(overview: &adw::TabOverview) -> gtk::Button {
    descendants(overview)
        .into_iter()
        .find_map(|widget| {
            let button = widget.downcast::<gtk::Button>().ok()?;
            let content = button.child()?.downcast::<adw::ButtonContent>().ok()?;
            (content.icon_name() == "adw-tab-new-symbolic").then_some(button)
        })
        .expect("the overview's new-tab button")
}

fn top_header(toolbar: &adw::ToolbarView) -> Option<adw::HeaderBar> {
    let mut child = toolbar.first_child();
    while let Some(widget) = child {
        if let Some(header) = descendants(&widget)
            .into_iter()
            .chain(std::iter::once(widget.clone()))
            .find_map(|widget| widget.downcast::<adw::HeaderBar>().ok())
        {
            return Some(header);
        }
        child = widget.next_sibling();
    }
    None
}

fn sized(name: &str, width: i32, height: i32) -> TestWindow {
    let test = TestWindow::with_script(
        name,
        Script {
            window_size: Some((width, height)),
            ..Script::default()
        },
    );
    // GTK fits a remembered size to the monitor, and xvfb-run on Fedora gives a 640x480 one.
    test.window.set_size_request(width, height);
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    test
}

#[gtk4::test]
fn each_pane_owns_its_header_bar() {
    let test = TestWindow::connected("PaneHeaders");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();

    let sidebar = top_header(&imp.sidebar_root).expect("the sidebar's header bar");
    let content = top_header(&imp.content_root).expect("the content's header bar");

    assert_eq!(sidebar, imp.sidebar_header.get());
    assert_eq!(content, imp.content_header.get());
    let assistant = descendants(&imp.assistant_stack.get())
        .into_iter()
        .find_map(|widget| widget.downcast::<adw::HeaderBar>().ok())
        .expect("the assistant's header bar");
    // The overview draws a header bar of its own while it is open.
    let headers: Vec<adw::HeaderBar> = descendants(&imp.breakpoint_bin.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::HeaderBar>().ok())
        .collect();
    assert_eq!(headers.len(), 3, "a header bar outside the three panes");
    assert!(headers.contains(&sidebar) && headers.contains(&content) && headers.contains(&assistant));
    assert!(
        descendants(&imp.sidebar_header.get()).iter().any(|widget| {
            widget
                .downcast_ref::<gtk::MenuButton>()
                .is_some_and(gtk::MenuButton::is_primary)
        }),
        "the main menu is not in the sidebar's header bar"
    );
}

#[gtk4::test]
fn tab_overview_is_the_window_content() {
    let test = TestWindow::connected("OverviewRoot");

    let content = test.window.content().expect("the window's content");
    let shell = content.downcast::<WorkspaceShell>().expect("the shell page");
    let overview = shell
        .child()
        .and_downcast::<adw::TabOverview>()
        .expect("the overview as the shell's only child");

    assert_eq!(overview.view(), Some(shell.imp().tab_view.get()));
    assert!(
        overview.child().is_some_and(|child| child.is::<adw::BreakpointBin>()),
        "the overview does not hold the header bars"
    );
}

#[gtk4::test]
fn tab_bar_is_a_content_top_bar() {
    let test = TestWindow::connected("TabBarTop");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();

    let bar = imp.tab_bar.get();

    assert_eq!(bar.view(), Some(imp.tab_view.get()));
    assert!(bar.is_autohide());
    assert_eq!(
        bar.ancestor(adw::ToolbarView::static_type()).as_ref(),
        Some(imp.content_root.upcast_ref::<gtk::Widget>())
    );
    assert!(
        bar.ancestor(gtk::Stack::static_type()).is_none(),
        "the tab bar sits in the tab area, not above it"
    );
}

#[gtk4::test]
fn show_sidebar_action_toggles_split_view() {
    let test = TestWindow::connected("ShowSidebar");
    let split = shell_of(&test.workspace()).imp().split_view.get();
    assert!(split.shows_sidebar());

    WidgetExt::activate_action(&test.window, "win.show-sidebar", None).expect("win.show-sidebar");
    assert!(!split.shows_sidebar());

    WidgetExt::activate_action(&test.window, "win.show-sidebar", None).expect("win.show-sidebar");
    assert!(split.shows_sidebar());
}

#[gtk4::test]
fn show_tabs_opens_and_closes_the_overview_while_a_tab_is_open() {
    let test = TestWindow::connected("ShowTabs");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let overview = shell.imp().tab_overview.get();
    let enabled = |name: &str| {
        test.window
            .lookup_action(name)
            .is_some_and(|action| action.is_enabled())
    };
    assert_eq!(shell.tab_view().n_pages(), 0);
    assert!(!enabled("show-tabs"), "the overview warns and stays shut with no tab");
    assert!(!enabled("switch-recent-tab"));

    super::open_editor(&workspace);
    assert!(enabled("show-tabs"));
    assert!(!enabled("switch-recent-tab"), "one tab has no other to go to");
    WidgetExt::activate_action(&test.window, "win.show-tabs", None).expect("win.show-tabs");
    assert!(overview.is_open());
    WidgetExt::activate_action(&test.window, "win.show-tabs", None).expect("win.show-tabs");
    assert!(!overview.is_open());

    super::open_editor(&workspace);
    assert!(enabled("switch-recent-tab"));
}

#[gtk4::test]
fn sidebar_toggle_visible_only_when_collapsed_or_hidden() {
    let test = TestWindow::connected("SidebarToggle");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();
    let (split, toggle) = (imp.split_view.get(), imp.sidebar_toggle.get());
    split.set_collapsed(false);
    split.set_show_sidebar(true);
    assert!(!toggle.is_visible(), "shown beside a sidebar in view");

    split.set_show_sidebar(false);
    assert!(toggle.is_visible(), "hidden with the sidebar hidden");

    split.set_show_sidebar(true);
    split.set_collapsed(true);
    assert!(toggle.is_visible(), "hidden with the sidebar collapsed");
    assert_eq!(toggle.action_name().as_deref(), Some("win.show-sidebar"));
}

#[gtk4::test]
fn narrow_window_swaps_tab_bar_for_tab_button() {
    let test = sized("Narrow", 360, 294);
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();

    wait_until(Duration::from_secs(2), || {
        imp.breakpoint_bin.current_breakpoint().as_ref() == Some(&imp.narrow_breakpoint.get())
    })
    .expect("the narrow breakpoint to apply");

    assert!(!imp.tab_bar.is_visible(), "the tab bar stayed");
    assert!(imp.tab_button.is_visible(), "no tab button took its place");
    assert!(imp.split_view.is_collapsed());
}

#[gtk4::test]
fn wide_window_shows_tab_bar() {
    let test = sized("Wide", 1200, 760);
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();
    wait_until(Duration::from_secs(2), || {
        imp.breakpoint_bin.width() > 0 && imp.breakpoint_bin.current_breakpoint().is_none()
    })
    .expect("the workspace laid out with no breakpoint");

    assert_eq!(imp.breakpoint_bin.current_breakpoint(), None);
    assert!(imp.tab_bar.is_visible());
    assert!(!imp.tab_button.is_visible());
    assert!(!imp.split_view.is_collapsed());
}

fn fits_the_floor(root: &gtk::Widget) {
    let (min_width, ..) = root.measure(gtk::Orientation::Horizontal, -1);
    let (min_height, ..) = root.measure(gtk::Orientation::Vertical, 360);
    assert!(min_width <= 360, "{} needs {min_width} px wide", root.type_().name());
    assert!(min_height <= 294, "{} needs {min_height} px high", root.type_().name());
}

#[gtk4::test]
fn every_page_fits_the_window_floor() {
    use tablepro_session::fakes::FakeEstablish;
    use tablepro_test_support::ConnectionScript;
    let test = TestWindow::with_script(
        "Floor",
        Script {
            establish: vec![
                FakeEstablish::Late {
                    after: Duration::from_secs(3),
                    script: ConnectionScript::default(),
                },
                crate::ui::session_window::tests::refused(),
            ],
            ..Script::default()
        },
    );
    assert_eq!(test.window.size_request(), (360, 294));
    let content = || test.window.content().expect("a page");
    fits_the_floor(&content());

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connecting");
    fits_the_floor(&content());
    // A cancel before the driver is asked leaves the late connect for
    // the next attempt.
    wait_until(Duration::from_secs(10), || !test.connector.calls().is_empty())
        .expect("the connect to reach the driver");

    test.window.send(SessionWindowInput::CancelConnect);
    test.wait_for_page("picker");
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("connect-failed");
    fits_the_floor(&content());

    test.window.send(SessionWindowInput::RetryConnect);
    test.wait_for_page("workspace");
    fits_the_floor(&content());
}

/// The floor measured on the tab's own content, with its widest
/// bars up: the pager's longest label, pending changes and the
/// filter strip.
#[gtk4::test]
fn an_open_table_tab_fits_the_window_floor() {
    use crate::ui::browse_tab::{BrowseTab, PagingInput};
    let test = TestWindow::with_script(
        "TableFloor",
        Script {
            connection: served_table(),
            window_size: Some((360, 294)),
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let workspace = test.workspace();
    let page = workspace
        .with_model(|model| {
            model.open_tab(super::super::tab_spec::TabSpec::Table {
                table: tablepro_core::meta::TableRef::new(Some("public".to_owned()), "customers"),
                page: super::super::tab_spec::TablePage::first(1_000),
                filter: crate::ui::browse_tab::TableFilter::Remembered,
            })
        })
        .flatten()
        .expect("a table tab");
    let tab = page.child().downcast::<BrowseTab>().expect("a browse tab");
    let wait = Duration::from_secs(10);
    wait_until(wait, || tab.grid().row_count() > 0).expect("the tab's rows");
    tab.activate_action("grid.insert-row", None)
        .expect("the tab inserts rows");
    let content =
        crate::test_support::first_descendant_of_type::<adw::ToolbarView>(&tab).expect("the tab's toolbar view");
    let needs = || {
        let (width, ..) = content.measure(gtk::Orientation::Horizontal, -1);
        if width > tab.width() {
            return (width, i32::MAX);
        }
        (width, content.measure(gtk::Orientation::Vertical, tab.width()).0)
    };

    let fits = wait_until(wait, || {
        let (width, height) = needs();
        tab.width() > 0 && width <= 360 && height <= tab.height()
    });
    assert!(
        fits.is_ok(),
        "an open table tab needs {:?} px, the tab has {}x{}",
        needs(),
        tab.width(),
        tab.height()
    );

    // Measured as it opens: at the floor's height the strip and the
    // grid cannot both have room, so the strip is checked for width.
    tab.send(PagingInput::ToggleFilterStrip);
    let (with_filter, ..) = content.measure(gtk::Orientation::Horizontal, -1);
    tab.send(PagingInput::ToggleFilterStrip);
    assert!(with_filter <= 360, "the filter strip needs {with_filter} px");
}

#[gtk4::test]
fn overview_new_tab_uses_tab_factory() {
    let test = TestWindow::connected("OverviewNewTab");
    let workspace = test.workspace();
    let overview = shell_of(&workspace).imp().tab_overview.get();

    // As the overview's own button emits it: create-tab hands back a
    // page it does not own, which emit_by_name would release.
    overview_new_tab_button(&overview).emit_clicked();
    let page = shell_of(&workspace)
        .imp()
        .tab_view
        .selected_page()
        .expect("the new tab's page");

    let slot = workspace
        .read(|model| {
            let id = model.index.id_of(&page)?;
            let tabs = model.workspace_tabs.borrow();
            Some(matches!(tabs.get(&id), Some(WorkspaceTab::Editor(_))))
        })
        .flatten();
    assert_eq!(slot, Some(true), "the page has no editor slot in the index");
    assert_eq!(page.title(), "Query 1");
}

#[gtk4::test]
fn primary_menu_has_no_quit() {
    let test = TestWindow::picker("PrimaryMenu");
    let menu = test.app.menu_by_id("primary_menu").expect("the primary menu");
    let mut actions = Vec::new();
    for section in 0..menu.n_items() {
        let Some(items) = menu.item_link(section, "section") else {
            continue;
        };
        for item in 0..items.n_items() {
            if let Some(action) = items
                .item_attribute_value(item, "action", None)
                .and_then(|value| value.get::<String>())
            {
                actions.push(action);
            }
        }
    }

    for expected in ["app.new-window", "app.preferences", "app.shortcuts", "app.about"] {
        assert!(actions.iter().any(|action| action == expected), "{expected} is missing");
    }
    assert!(!actions.iter().any(|action| action == "app.quit"), "the menu has Quit");
    assert!(
        test.app.menu_by_id("tab_overview_menu").is_some(),
        "the overview's menu is missing"
    );
}

#[gtk4::test]
fn f9_toggles_sidebar() {
    let test = TestWindow::picker("F9");

    assert_eq!(test.app.accels_for_action("win.show-sidebar"), ["F9"]);
}

/// A session that comes forward with a tab it opened while handling
/// its own input still gives the overview its new tab.
#[gtk4::test]
fn the_overview_opens_a_tab_in_a_session_that_came_forward_from_its_own_input() {
    let sessions = super::two_sessions("OverviewFollowsFront", "Other");
    let (shell, first, second) = (&sessions.shell, &sessions.first, &sessions.second);
    super::open_editor(first);
    super::open_editor(second);
    assert_eq!(shell.front().as_ref(), Some(second));
    let before = shell.tab_view().n_pages();

    overview_new_tab_button(&shell.imp().tab_overview.get()).emit_clicked();

    assert_eq!(shell.tab_view().n_pages(), before + 1, "the overview made no tab");
    let page = shell.tab_view().selected_page().expect("the new tab in front");
    assert_eq!(
        shell.owner_of(&page).map(|(owner, _)| owner).as_ref(),
        Some(second),
        "the new tab went to a session behind"
    );
}

/// Choose New Connection… in the main menu under `header`, as a click
/// does, and wait for the connection dialog.
fn choose_new_connection(test: &TestWindow, header: &impl IsA<gtk::Widget>) {
    let button = descendants(header)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::MenuButton>().ok())
        .find(gtk::MenuButton::is_primary)
        .expect("the main menu button");
    button.popup();
    let menu = button.popover().expect("the main menu");
    wait_until(WAIT, || menu.is_visible()).expect("the main menu to open");
    // GTK keeps a menu item private and gives it no action name.
    let item = descendants(&menu)
        .into_iter()
        .find(|widget| {
            widget.type_().name() == "GtkModelButton"
                && widget.property::<Option<String>>("text").as_deref() == Some("New Connection…")
        })
        .expect("New Connection… in the main menu");
    wait_until(WAIT, || item.is_sensitive()).expect("New Connection… to be enabled");

    item.emit_by_name::<()>("clicked", &[]);

    wait_until(WAIT, || test.window.visible_dialog().is_some()).expect("the connection dialog");
}

#[gtk4::test]
fn the_main_menu_adds_a_connection_beside_an_open_one() {
    let test = TestWindow::connected("MainMenuNewConnection");
    // The overview's own menu button is a primary one too.
    let header = shell_of(&test.workspace()).imp().sidebar_header.get();
    choose_new_connection(&test, &header);
}

#[gtk4::test]
fn the_main_menu_adds_a_connection_with_none_open() {
    let test = TestWindow::picker("PickerMenuNewConnection");
    let menu = test.app.menu_by_id("primary_menu").expect("the primary menu");
    let first = menu.item_link(0, "section").expect("a first section");
    assert_eq!(
        first
            .item_attribute_value(0, "action", None)
            .and_then(|value| value.get::<String>())
            .as_deref(),
        Some("win.new-connection"),
        "New Connection… does not lead the menu"
    );

    choose_new_connection(&test, &test.window.content().expect("the picker"));
}
