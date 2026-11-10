//! The shell's chrome: the header bars, the sidebar, the breakpoints and
//! the window floor, the overview and the main menu.

use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::{EditorSession, ResultEvent, Truncation, Value};
use tablepro_test_support::{FakeEditorSession, FakeReply, FakeRun, Replies};

use super::{served_table, shell_of};
use crate::test_support::{descendants, wait_until};
use crate::ui::SessionWindowInput;
use crate::ui::session_window::tests::{Script, TestWindow, WAIT, editors};
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
fn the_sidebar_toggle_is_always_in_the_header() {
    let test = TestWindow::connected("SidebarToggle");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();
    let (split, toggle) = (imp.split_view.get(), imp.sidebar_toggle.get());
    crate::test_support::assert_labelled(&toggle).expect("the sidebar toggle is named");
    assert_eq!(toggle.tooltip_text().as_deref(), Some("Show Sidebar"));
    assert_eq!(toggle.action_name().as_deref(), Some("win.show-sidebar"));

    for collapsed in [false, true] {
        split.set_collapsed(collapsed);
        split.set_show_sidebar(true);
        assert!(toggle.is_visible());
        assert!(toggle.is_active());

        toggle.emit_clicked();
        assert!(!split.shows_sidebar());
        assert!(!toggle.is_active());
        assert!(toggle.is_visible());

        toggle.emit_clicked();
        assert!(split.shows_sidebar());
        assert!(toggle.is_active());

        WidgetExt::activate_action(&test.window, "win.show-sidebar", None).expect("win.show-sidebar");
        assert!(!split.shows_sidebar());
        assert!(!toggle.is_active());
        assert!(toggle.is_visible());
    }
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
    assert!(
        !imp.new_tab_button.is_visible(),
        "New Query stayed beside the tab button"
    );
    assert!(imp.tab_overview.property::<bool>("enable-new-tab"));
    assert!(imp.split_view.is_collapsed());
    let button = session_menu_button(&test);
    wait_until(WAIT, || button.is_mapped()).expect("Session Menu at the window floor");
    assert!(imp.content_header.measure(gtk::Orientation::Horizontal, -1).0 <= 360);
    button.popup();
    wait_until(WAIT, || button.popover().is_some_and(|menu| menu.is_mapped())).expect("the narrow menu opens");
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

#[gtk4::test]
fn save_changes_leaves_the_narrow_header() {
    for (name, width, height, shown) in [("NarrowSave", 360, 294, false), ("WideSave", 1200, 760, true)] {
        let test = sized(name, width, height);
        let workspace = test.workspace();
        let shell = shell_of(&workspace);
        let imp = shell.imp();
        let narrow = (!shown).then(|| imp.narrow_breakpoint.get());
        wait_until(Duration::from_secs(2), || {
            imp.breakpoint_bin.width() > 0 && imp.breakpoint_bin.current_breakpoint() == narrow
        })
        .expect("the breakpoint for the width");
        assert_eq!(imp.save_changes_button.is_visible(), shown, "{name}");
    }
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

#[gtk4::test]
fn an_open_table_tab_fits_the_window_floor() {
    table_tab_fits_the_window_floor(false);
}

#[gtk4::test]
fn a_table_tab_with_structure_switch_fits_the_window_floor() {
    table_tab_fits_the_window_floor(true);
}

fn table_tab_fits_the_window_floor(with_structure: bool) {
    use crate::ui::browse_tab::{BrowseTab, PagingInput};
    let mut connection = served_table();
    if with_structure {
        connection.dialect = Arc::new(tablepro_driver_postgres::PgDialect::new(
            &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
        ));
    }
    let test = TestWindow::with_script(
        "TableFloor",
        Script {
            connection,
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
fn application_and_session_commands_have_separate_native_menus() {
    let test = TestWindow::connected("NativeMenus");
    assert!(
        test.app.menubar().is_none(),
        "AdwApplicationWindow does not support a menu bar"
    );
    let primary = test.app.menu_by_id("primary_menu").expect("the primary menu");
    let mut app_actions = Vec::new();
    collect_actions(primary.upcast_ref(), &mut app_actions);
    assert_eq!(app_actions.len(), 10);
    let button = session_menu_button(&test);
    assert!(!button.is_primary(), "F10 belongs to Main Menu");
    crate::test_support::assert_labelled(&button).expect("the menu's accessible name");
    let mut session_actions = Vec::new();
    collect_actions(&button.menu_model().expect("the session menu"), &mut session_actions);
    for expected in [
        "win.safe-mode",
        "win.show-history",
        "win.show-saved-queries",
        "win.export-database",
        "win.import-sql-file",
        "win.disconnect",
    ] {
        assert!(
            session_actions.iter().any(|action| action == expected),
            "{expected} is missing"
        );
        assert!(
            !app_actions.iter().any(|action| action == expected),
            "{expected} is duplicated"
        );
    }
    for action in &app_actions {
        assert!(!session_actions.contains(action), "{action} belongs to Main Menu");
    }
}

fn session_menu_button(test: &TestWindow) -> gtk::MenuButton {
    let shell = test.window.shell().expect("the workspace shell");
    descendants(&shell.imp().content_header.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::MenuButton>().ok())
        .find(|button| button.tooltip_text().as_deref() == Some("Session Menu"))
        .expect("Session Menu in the content header")
}

fn click_menu_item(menu: &gtk::Popover, label: &str) {
    let mut found = None;
    wait_until(WAIT, || {
        found = descendants(menu).into_iter().find(|widget| {
            widget.type_().name() == "GtkModelButton"
                && widget.property::<Option<String>>("text").as_deref() == Some(label)
                && widget.is_mapped()
                && widget.is_sensitive()
        });
        found.is_some()
    })
    .unwrap_or_else(|_| panic!("no enabled menu item {label}"));
    found.expect("the item").emit_by_name::<()>("clicked", &[]);
}

#[gtk4::test]
fn the_session_menu_changes_safe_mode_through_its_radio_item() {
    let test = TestWindow::connected("SessionMenuSafeMode");
    let button = session_menu_button(&test);
    button.popup();
    let menu = button.popover().expect("the session menu");
    click_menu_item(&menu, "Safe Mode");
    click_menu_item(&menu, "Confirm Writes");
    wait_until(WAIT, || {
        test.window
            .front_session()
            .is_some_and(|(_, session)| session.safe_mode() == tablepro_core::SafeModeLevel::ConfirmWrites)
    })
    .expect("the selected level to reach the session");
    assert_eq!(
        test.window
            .lookup_action("safe-mode")
            .and_then(|action| action.state())
            .and_then(|state| state.get::<String>()),
        Some("confirm-writes".to_owned())
    );
}

#[gtk4::test]
fn the_session_menu_disconnects_the_session_in_front() {
    let test = TestWindow::connected("SessionMenuDisconnect");
    let button = session_menu_button(&test);
    button.popup();
    click_menu_item(&button.popover().expect("the menu"), "Disconnect");
    test.wait_for_page("picker");
    assert!(test.window.front_session().is_none());
    assert!(!descendants(&test.window).iter().any(|widget| {
        widget
            .downcast_ref::<gtk::MenuButton>()
            .is_some_and(|button| button.tooltip_text().as_deref() == Some("Session Menu"))
    }));
}

#[gtk4::test]
fn f9_toggles_sidebar() {
    let test = TestWindow::picker("F9");

    assert_eq!(test.app.accels_for_action("win.show-sidebar"), ["F9"]);
}

#[gtk4::test]
fn ctrl_shift_e_exports_results() {
    use crate::test_support::shortcut_keys::keystroke;
    let test = TestWindow::picker("CtrlShiftE");

    let installed = test.app.accels_for_action("win.export-results");
    let keys: Vec<_> = installed.iter().map(|accel| keystroke(accel)).collect();
    assert_eq!(keys, [keystroke("<Primary><Shift>e")]);
}

fn two_rows() -> Arc<dyn EditorSession> {
    let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("text"))].into();
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(vec![
        ResultEvent::ResultSetStarted { columns },
        ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
        ResultEvent::ResultSetFinished {
            retained: 2,
            total_rows: Some(2),
            truncation: Truncation::Complete,
        },
    ]));
    Arc::new(FakeEditorSession::new(runs))
}

fn export_results(test: &TestWindow) {
    WidgetExt::activate_action(&test.window, "win.export-results", None).expect("win.export-results");
}

fn wait_for_export_dialog(test: &TestWindow) {
    wait_until(WAIT, || test.window.visible_dialog().is_some()).expect("the export dialog");
    let dialog = test.window.visible_dialog().expect("the export dialog");
    assert_eq!(dialog.title(), "Export Rows");
}

#[gtk4::test]
fn export_results_offers_the_result_an_editor_shows() {
    let session = two_rows();
    let test = TestWindow::connected_with("ExportResultsEditor", |script| {
        script.open_editor_session.always(FakeReply::ok(session));
    });
    test.run_in_new_editor_tab();

    export_results(&test);

    wait_for_export_dialog(&test);
}

#[gtk4::test]
fn export_results_offers_the_rows_a_table_tab_shows() {
    use crate::ui::browse_tab::BrowseTab;
    let test = TestWindow::connected_with("ExportResultsTable", |script| *script = served_table());
    let page = test
        .workspace()
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
    wait_until(WAIT, || tab.grid().row_count() > 0).expect("the tab's rows");

    export_results(&test);

    wait_for_export_dialog(&test);
}

#[gtk4::test]
fn export_results_says_when_the_tab_in_front_has_no_rows() {
    let test = TestWindow::connected("ExportResultsNothing");
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab that has not run");
    let overlay = shell_of(&test.workspace()).toast_overlay();

    export_results(&test);

    wait_until(WAIT, || {
        descendants(&overlay)
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk::Label>())
            .any(|label| label.label() == "Nothing to export")
    })
    .expect("the toast says there is nothing to export");
    assert_eq!(test.window.visible_dialog(), None, "a dialog opened with no rows");
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

fn collect_actions(menu: &gio::MenuModel, actions: &mut Vec<String>) {
    for item in 0..menu.n_items() {
        if let Some(action) = menu
            .item_attribute_value(item, "action", None)
            .and_then(|value| value.get::<String>())
        {
            actions.push(action);
        }
        for link in ["section", "submenu"] {
            if let Some(inner) = menu.item_link(item, link) {
                collect_actions(&inner, actions);
            }
        }
    }
}

#[gtk4::test]
fn open_quickly_closes_when_another_session_comes_forward() {
    let sessions = super::two_sessions("QuickOpenFollowsFront", "Other");
    super::open_editor(&sessions.first);
    let dialog = sessions
        .first
        .with_model(|model| {
            model.on_show_quick_open();
            model.quick_open_dialog.clone().expect("quick open")
        })
        .expect("workspace");
    wait_until(WAIT, || dialog.parent().is_some()).expect("shown");
    super::open_editor(&sessions.second);
    wait_until(WAIT, || dialog.parent().is_none()).expect("old session dialog closed");
    assert_eq!(sessions.shell.front().as_ref(), Some(&sessions.second));
}

#[gtk4::test]
fn a_queued_quick_open_pick_does_not_reopen_a_background_session() {
    let sessions = super::two_sessions("QuickOpenQueuedPick", "Other");
    super::open_editor(&sessions.second);
    let before = sessions.shell.tab_view().n_pages();
    sessions.first.with_model(|model| {
        model.on_quick_open_chosen(crate::ui::quick_open::Pick::Table {
            table: tablepro_core::meta::TableRef::new(None, "orders"),
            structure: false,
        })
    });
    assert_eq!(sessions.shell.front().as_ref(), Some(&sessions.second));
    assert_eq!(sessions.shell.tab_view().n_pages(), before);
}

#[gtk4::test]
fn the_header_refresh_follows_the_selected_tabs_capability() {
    use super::super::structure_target::StructureTarget;
    use super::super::tab_spec::{TabSpec, TablePage};
    use crate::ui::browse_tab::TableFilter;
    use tablepro_core::meta::TableRef;

    let test = TestWindow::connected("HeaderRefresh");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let button = shell.imp().refresh_page_button.get();
    assert_eq!(button.action_name().as_deref(), Some("win.refresh-page"));
    crate::test_support::assert_labelled(&button).expect("the refresh button is named");
    assert!(gtk::test_accessible_has_property(
        &button,
        gtk::AccessibleProperty::KeyShortcuts
    ));
    assert!(!button.is_sensitive(), "there is no tab to refresh");

    let table = workspace
        .with_model(|model| {
            model.open_tab(TabSpec::Table {
                table: TableRef::unqualified("customers"),
                page: TablePage::first(100),
                filter: TableFilter::Remembered,
            })
        })
        .flatten()
        .expect("a table");
    wait_until(WAIT, || button.is_sensitive()).expect("table refresh");
    super::open_editor(&workspace);
    wait_until(WAIT, || !button.is_sensitive()).expect("no editor rerun");
    workspace
        .with_model(|model| {
            model.open_tab(TabSpec::Structure {
                target: StructureTarget::Existing(TableRef::unqualified("customers")),
            })
        })
        .flatten()
        .expect("a structure draft");
    wait_until(WAIT, || !button.is_sensitive()).expect("no draft to reload");
    workspace.with_model(|model| model.tab_view.set_selected_page(&table));
    wait_until(WAIT, || button.is_sensitive()).expect("refresh after selection inside the model");

    for page in (0..shell.tab_view().n_pages())
        .map(|i| shell.tab_view().nth_page(i))
        .collect::<Vec<_>>()
    {
        shell.tab_view().close_page(&page);
    }
    wait_until(WAIT, || shell.tab_view().n_pages() == 0).expect("all clean tabs close");
    wait_until(WAIT, || !button.is_sensitive()).expect("no refresh after the last tab closes");
}

fn postgres(script: &mut tablepro_test_support::ConnectionScript) {
    script.dialect = Arc::new(tablepro_driver_postgres::PgDialect::new(
        &tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0),
    ));
}

#[gtk4::test]
fn the_sidebar_add_menu_makes_objects_in_the_session_in_front() {
    let test = TestWindow::connected_with("SidebarAdd", postgres);
    let shell = shell_of(&test.workspace());
    let imp = shell.imp();
    let (bar, button) = (imp.sidebar_bar.get(), imp.sidebar_add_button.get());
    wait_until(WAIT, || bar.is_revealed()).expect("the bar under the tree");
    crate::test_support::assert_labelled(&button).expect("the Add button is named");
    let target = crate::ui::session_target::to_variant(&test.key());
    let offered = button
        .menu_model()
        .map(|menu| crate::ui::workspace::sidebar::tests::menu_items(&menu))
        .unwrap_or_default();
    assert_eq!(
        offered,
        [
            ("win.new-table-in".to_owned(), Some(target.clone())),
            ("win.new-schema-in".to_owned(), Some(target.clone())),
            ("win.new-database-in".to_owned(), Some(target.clone())),
        ]
    );

    imp.scope_toggle.set_active_name(Some("favorites"));
    assert!(!bar.is_revealed(), "the bar makes tables under Favorites");
    imp.scope_toggle.set_active_name(Some("tables"));
    assert!(bar.is_revealed());

    WidgetExt::activate_action(&button, "win.new-table-in", Some(&target)).expect("the window's action");
    wait_until(WAIT, || shell.tab_view().n_pages() == 1).expect("a new table's tab");
}

#[gtk4::test]
fn a_read_only_connection_has_no_add_menu() {
    let test = TestWindow::connected_with("SidebarAddReadOnly", |script| {
        postgres(script);
        script.read_only = true;
    });
    let shell = shell_of(&test.workspace());
    let imp = shell.imp();
    wait_until(WAIT, || test.workspace().creation_menu().is_some()).expect("the session's Add menu");

    assert_eq!(test.workspace().creation_menu().map(|menu| menu.n_items()), Some(0));
    assert!(!imp.sidebar_add_button.is_visible());
    assert!(!imp.sidebar_bar.is_revealed());
}

#[gtk4::test]
fn the_schemas_button_chooses_what_the_sidebar_lists_and_keeps_it() {
    let test = TestWindow::connected("SchemaFilter");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let (button, bar) = (shell.imp().schema_filter_button.get(), shell.imp().sidebar_bar.get());
    let banner = workspace.imp().schema_filter_banner.get();
    assert!(!button.is_visible(), "one schema has nothing to choose among");

    let schema = |name: &str| tablepro_core::meta::SchemaInfo {
        name: name.to_owned(),
        is_default: name == "public",
        is_system: false,
    };
    let session = workspace
        .read(|model| model.context.active.get())
        .flatten()
        .expect("the session");
    session
        .catalog()
        .commit(vec![schema("public"), schema("sales")], Vec::new());
    wait_until(WAIT, || button.is_visible()).expect("the Schemas button");
    assert_eq!(button.label().as_deref(), Some("Schemas"));
    assert!(bar.is_revealed());
    assert!(!banner.is_revealed());

    button.popup();
    let popover = button.popover().expect("the chooser");
    let check = |name: &str| {
        descendants(&popover)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::CheckButton>().ok())
            .find(|check| check.label().as_deref() == Some(name))
    };
    wait_until(WAIT, || check("sales").is_some()).expect("a check for each schema");
    check("sales").expect("the sales check").set_active(false);
    wait_until(WAIT, || banner.is_revealed()).expect("the banner");
    assert_eq!(banner.title(), "Showing 1 of 2 schemas");
    let (id, database) = (session.metadata().id, session.database().unwrap_or_default().to_owned());
    let filters = test.services.storage.filter_settings().clone();
    assert_eq!(
        filters.sidebar_schemas(id, &database),
        std::collections::BTreeSet::from(["public".to_owned()])
    );
    wait_until(WAIT, || check("public").is_some_and(|check| !check.is_sensitive()))
        .expect("the last schema listed stays");

    banner.emit_by_name::<()>("button-clicked", &[]);
    wait_until(WAIT, || !banner.is_revealed()).expect("Show All");
    assert!(filters.sidebar_schemas(id, &database).is_empty());
}
