//! The workspace's two header bars, the sidebar's and the content's,
//! and what they need beyond the template: the main menu, the button
//! labels, the sidebar toggle and the overview's new tab.

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

use super::Workspace;
use super::tab_factory::TabFactory;
use crate::ui::a11y::describe_icon_button;
use crate::ui::shell::{TAB_OVERVIEW_MENU, app_menu, primary_menu_button};

/// The window action that shows and hides the sidebar, as GNOME Files
/// names it.
pub(super) const SHOW_SIDEBAR: &str = "show-sidebar";

/// What `install` connected outside the template, let go of at shutdown.
pub(super) struct ShellHandles {
    overview: glib::WeakRef<adw::TabOverview>,
    create_tab: Option<glib::SignalHandlerId>,
    sidebar_toggle: Option<gtk::ExpressionWatch>,
}

impl ShellHandles {
    pub(super) fn release(&mut self) {
        if let Some(watch) = self.sidebar_toggle.take() {
            watch.unwatch();
        }
        if let Some(handler) = self.create_tab.take()
            && let Some(overview) = self.overview.upgrade()
        {
            overview.disconnect(handler);
        }
    }
}

/// Run as the workspace is built, so its buttons are named before any
/// window holds it.
pub(super) fn describe_buttons(workspace: &Workspace) {
    let imp = workspace.imp();
    describe_icon_button(
        &imp.table_search_toggle.get(),
        &crate::i18n::gettext("Search Tables"),
        None,
    );
    describe_icon_button(
        &imp.refresh_tables_button.get(),
        &crate::i18n::gettext("Refresh Tables"),
        Some("win.refresh-tables"),
    );
    describe_icon_button(
        &imp.sidebar_toggle.get(),
        &crate::i18n::gettext("Show Sidebar"),
        Some("win.show-sidebar"),
    );
    describe_icon_button(
        &imp.new_tab_button.get(),
        &crate::i18n::gettext("New Query"),
        Some("win.new-editor-tab"),
    );
    describe_icon_button(&imp.tab_button.get(), &crate::i18n::gettext("View Open Tabs"), None);
}

pub(super) fn install(
    workspace: &Workspace,
    window: &adw::ApplicationWindow,
    factory: &Rc<TabFactory>,
) -> ShellHandles {
    let imp = workspace.imp();
    let app = window.application();
    imp.sidebar_header.pack_end(&primary_menu_button(app.as_ref()));

    window.add_action(&gio::PropertyAction::new(
        SHOW_SIDEBAR,
        &imp.split_view.get(),
        "show-sidebar",
    ));
    let sidebar_toggle = follow_sidebar(&imp.split_view, &imp.sidebar_toggle);

    imp.tab_view
        .bind_property("n-pages", &imp.tab_stack.get(), "visible-child-name")
        .transform_to(|_, pages: i32| Some(if pages > 0 { "tabs" } else { "empty" }))
        .sync_create()
        .build();

    let overview = imp.tab_overview.get();
    if let Some(menu) = app_menu(app.as_ref(), TAB_OVERVIEW_MENU) {
        overview.set_secondary_menu(Some(&menu));
    }
    // The overview selects the page it gets back.
    let factory = factory.clone();
    let create_tab = overview.connect_create_tab(move |_| factory.create_editor());
    ShellHandles {
        overview: overview.downgrade(),
        create_tab: Some(create_tab),
        sidebar_toggle: Some(sidebar_toggle),
    }
}

/// The toggle shows only while the sidebar is out of view: collapsed
/// into an overlay, or hidden. Beside a shown sidebar it would only hide
/// the list the user is looking at.
fn follow_sidebar(split_view: &adw::OverlaySplitView, toggle: &gtk::ToggleButton) -> gtk::ExpressionWatch {
    let collapsed = gtk::PropertyExpression::new(
        adw::OverlaySplitView::static_type(),
        None::<&gtk::Expression>,
        "collapsed",
    );
    let shown = gtk::PropertyExpression::new(
        adw::OverlaySplitView::static_type(),
        None::<&gtk::Expression>,
        "show-sidebar",
    );
    let visible = gtk::ClosureExpression::new::<bool>(
        [collapsed, shown],
        glib::closure!(|_: Option<glib::Object>, collapsed: bool, shown: bool| collapsed || !shown),
    );
    visible.bind(toggle, "visible", Some(split_view))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use libadwaita::prelude::*;

    use super::*;
    use crate::test_support::{descendants, wait_until};
    use crate::ui::SessionWindowInput;
    use crate::ui::session_window::tests::{Script, TestWindow};
    use crate::ui::workspace::WorkspaceTab;

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
        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        test
    }

    #[gtk4::test]
    fn each_pane_owns_its_header_bar() {
        let test = TestWindow::connected("PaneHeaders");
        let workspace = test.workspace();
        let imp = workspace.imp();

        let sidebar = top_header(&imp.sidebar_root).expect("the sidebar's header bar");
        let content = top_header(&imp.content_root).expect("the content's header bar");

        assert_eq!(sidebar, imp.sidebar_header.get());
        assert_eq!(content, imp.content_header.get());
        // The overview draws a header bar of its own while it is open.
        let headers: Vec<adw::HeaderBar> = descendants(&imp.breakpoint_bin.get())
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::HeaderBar>().ok())
            .collect();
        assert_eq!(headers.len(), 2, "a header bar outside the two panes");
        assert!(headers.contains(&sidebar) && headers.contains(&content));
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
        let workspace = content.downcast::<Workspace>().expect("the workspace page");
        let overview = workspace
            .child()
            .and_downcast::<adw::TabOverview>()
            .expect("the overview as the workspace's only child");

        assert_eq!(overview.view(), Some(workspace.imp().tab_view.get()));
        assert!(
            overview.child().is_some_and(|child| child.is::<adw::BreakpointBin>()),
            "the overview does not hold the header bars"
        );
    }

    #[gtk4::test]
    fn tab_bar_is_a_content_top_bar() {
        let test = TestWindow::connected("TabBarTop");
        let workspace = test.workspace();
        let imp = workspace.imp();

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
        let split = test.workspace().imp().split_view.get();
        assert!(split.shows_sidebar());

        WidgetExt::activate_action(&test.window, "win.show-sidebar", None).expect("win.show-sidebar");
        assert!(!split.shows_sidebar());

        WidgetExt::activate_action(&test.window, "win.show-sidebar", None).expect("win.show-sidebar");
        assert!(split.shows_sidebar());
    }

    #[gtk4::test]
    fn sidebar_toggle_visible_only_when_collapsed_or_hidden() {
        let test = TestWindow::connected("SidebarToggle");
        let workspace = test.workspace();
        let imp = workspace.imp();
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
        let imp = workspace.imp();

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
        let imp = workspace.imp();
        wait_until(Duration::from_secs(2), || imp.breakpoint_bin.width() > 0).expect("the workspace laid out");

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

    #[gtk4::test]
    fn overview_new_tab_uses_tab_factory() {
        let test = TestWindow::connected("OverviewNewTab");
        let workspace = test.workspace();
        let overview = workspace.imp().tab_overview.get();

        // As the overview's own button emits it: create-tab hands back a
        // page it does not own, which emit_by_name would release.
        overview_new_tab_button(&overview).emit_clicked();
        let page = workspace.imp().tab_view.selected_page().expect("the new tab's page");

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
}
