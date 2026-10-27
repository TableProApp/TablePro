//! The part of the workspace a window has once: the two header bars,
//! the sidebar, the one tab view every session's tabs share, the
//! assistant's column and the toasts. Each session keeps its own
//! `Workspace`, and the shell lets the one whose tab is in front speak
//! for the window.

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::BinExt;
use uuid::Uuid;

use std::rc::Rc;

use tablepro_session::SessionKey;

use super::sidebar::{ConnectionTree, TreeRequest};
use super::workspace_shell_imp as imp;
use super::{Workspace, WorkspaceInput};
use crate::runtime::DeliverInput;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::a11y::describe_icon_button;
use crate::ui::shell::{PRIMARY_MENU, TAB_OVERVIEW_MENU, app_menu, primary_menu_button};

/// The window action that shows and hides the sidebar, as GNOME Files
/// names it.
pub(super) const SHOW_SIDEBAR: &str = "show-sidebar";

/// The window action that shows and hides the assistant's column.
pub(super) const SHOW_ASSISTANT: &str = "show-assistant";

glib::wrapper! {
    pub struct WorkspaceShell(ObjectSubclass<imp::WorkspaceShell>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for WorkspaceShell {
    fn default() -> Self {
        glib::Object::new()
    }
}

/// Run as the shell is built, so its buttons are named before any
/// window holds it.
pub(super) fn describe_buttons(shell: &WorkspaceShell) {
    let imp = shell.imp();
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
    describe_icon_button(
        &imp.assistant_toggle.get(),
        &crate::i18n::gettext("Show the Assistant"),
        Some("win.show-assistant"),
    );
}

impl WorkspaceShell {
    /// A shell for `window`, with what it needs beyond the template: the
    /// main menu, the sidebar and assistant actions, the tab menu and the
    /// overview's new tab.
    pub(crate) fn new(window: &adw::ApplicationWindow, saved: Rc<SavedConnectionList>) -> Self {
        let shell = Self::default();
        let imp = shell.imp();
        let tree = ConnectionTree::new(saved);
        imp.sidebar_slot.set_child(Some(tree.widget()));
        tree.follow_search(&imp.table_search);
        imp.tree.replace(Some(tree));
        let app = window.application();
        let menu_button = primary_menu_button(app.as_ref());
        if let Some(menu) = app_menu(app.as_ref(), PRIMARY_MENU) {
            menu_button.set_menu_model(Some(&with_safe_mode(&menu)));
        }
        imp.sidebar_header.pack_end(&menu_button);

        window.add_action(&gio::PropertyAction::new(
            SHOW_SIDEBAR,
            &imp.split_view.get(),
            "show-sidebar",
        ));
        follow_sidebar(&imp.split_view, &imp.sidebar_toggle);
        window.add_action(&assistant_action(&shell));

        imp.tab_view
            .bind_property("n-pages", &imp.tab_stack.get(), "visible-child-name")
            .transform_to(|_, pages: i32| Some(if pages > 0 { "tabs" } else { "empty" }))
            .sync_create()
            .build();
        super::workspace_tab_view::keep_child_navigation_keys(&imp.tab_view);
        shell.connect_overview(app.as_ref());
        shell.connect_tab_menu();
        let follows = shell.downgrade();
        imp.tab_view.connect_selected_page_notify(move |_| {
            if let Some(shell) = follows.upgrade() {
                shell.follow_selected_page();
            }
        });

        imp.table_search_bar.connect_entry(&*imp.table_search);
        imp.table_search_bar.set_key_capture_widget(Some(&*imp.sidebar_root));
        imp.table_search_toggle
            .bind_property("active", &*imp.table_search_bar, "search-mode-enabled")
            .bidirectional()
            .sync_create()
            .build();

        let jobs = gio::ListStore::new::<gio::ListModel>();
        imp.export_operations_button
            .bind(&gtk::FlattenListModel::new(Some(jobs.clone())));
        imp.export_jobs.replace(Some(jobs));
        shell
    }

    /// The overview's new tab opens an editor on the session in front.
    /// The overview selects the page it gets back.
    fn connect_overview(&self, app: Option<&gtk::Application>) {
        let overview = self.imp().tab_overview.get();
        if let Some(menu) = app_menu(app, TAB_OVERVIEW_MENU) {
            overview.set_secondary_menu(Some(&menu));
        }
        let shell = self.downgrade();
        overview.connect_create_tab(move |overview| {
            let page = shell
                .upgrade()
                .and_then(|shell| shell.front())
                .and_then(|front| front.create_editor_page());
            page.unwrap_or_else(|| {
                // The overview needs a page back; with no session there is
                // nothing to open, so it gets one that closes at once.
                let view = overview.view().unwrap_or_default();
                let page = view.append(&adw::Bin::new());
                view.close_page(&page);
                page
            })
        });
    }

    /// The tab menu's bulk closes go to the session the tab belongs to,
    /// and close only that session's tabs.
    fn connect_tab_menu(&self) {
        let imp = self.imp();
        let target = self.downgrade();
        imp.tab_view.connect_setup_menu(move |_, page| {
            if let Some(shell) = target.upgrade() {
                shell.imp().menu_target.replace(page.cloned());
            }
        });
        let group = gio::SimpleActionGroup::new();
        let menu_action = |name: &str, message: fn(Uuid) -> WorkspaceInput| {
            let action = gio::SimpleAction::new(name, None);
            let shell = self.downgrade();
            action.connect_activate(move |_, _| {
                let Some(shell) = shell.upgrade() else {
                    return;
                };
                let page = shell.imp().menu_target.borrow().clone();
                if let Some(page) = page {
                    shell.deliver_for_page(&page, message);
                }
            });
            action
        };
        group.add_action(&menu_action("close-others", WorkspaceInput::CloseOtherWorkspaceTabs));
        group.add_action(&menu_action("close-right", WorkspaceInput::CloseWorkspaceTabsToRight));
        imp.tab_view.insert_action_group("tab", Some(&group));
        let menu = gio::Menu::new();
        menu.append(
            Some(&crate::i18n::gettext("Close Other Tabs")),
            Some("tab.close-others"),
        );
        menu.append(
            Some(&crate::i18n::gettext("Close Tabs to the Right")),
            Some("tab.close-right"),
        );
        imp.tab_view.set_menu_model(Some(&menu));
    }

    fn deliver_for_page(&self, page: &adw::TabPage, message: fn(Uuid) -> WorkspaceInput) {
        let owner = self.owner_of(page);
        if let Some((workspace, id)) = owner
            && let Some(input) = workspace.input()
        {
            input.deliver(message(id));
        }
    }

    /// The session that shows `page`, with the tab's id.
    pub(crate) fn owner_of(&self, page: &adw::TabPage) -> Option<(Workspace, Uuid)> {
        self.sessions()
            .into_iter()
            .find_map(|workspace| workspace.tab_id(page).map(|id| (workspace, id)))
    }

    /// The tab view every session's tabs share.
    pub(crate) fn tab_view(&self) -> adw::TabView {
        self.imp().tab_view.get()
    }

    /// Where the window shows its toasts while it shows the shell: under
    /// the header bars, inside the tab overview.
    pub(crate) fn toast_overlay(&self) -> adw::ToastOverlay {
        self.imp().toast_overlay.get()
    }

    pub(crate) fn sessions(&self) -> Vec<Workspace> {
        self.imp().sessions.borrow().clone()
    }

    /// The session the header bars and the window's actions speak for.
    pub(crate) fn front(&self) -> Option<Workspace> {
        self.imp().front.borrow().clone()
    }

    /// Where the connection tree's requests for the window go: to
    /// connect, disconnect, show or edit a connection. Its requests for a
    /// session's tables go to the session's workspace.
    pub(crate) fn set_tree_requests(&self, window_requests: impl Fn(TreeRequest) + 'static) {
        let shell = self.downgrade();
        let tree = self.imp().tree.borrow().clone();
        if let Some(tree) = tree {
            tree.set_requests(move |request| {
                let Some(shell) = shell.upgrade() else {
                    return;
                };
                match request {
                    TreeRequest::Table(key, event) => {
                        if let Some(workspace) = shell.session(&key) {
                            workspace.sidebar_event(event);
                        }
                    }
                    TreeRequest::NewQuery(key) => shell.deliver_to(&key, WorkspaceInput::NewEditorTab),
                    TreeRequest::Refresh(key) => shell.deliver_to(&key, WorkspaceInput::RefreshCatalog),
                    request => window_requests(request),
                }
            });
        }
    }

    fn deliver_to(&self, key: &SessionKey, message: WorkspaceInput) {
        if let Some(input) = self.session(key).and_then(|workspace| workspace.input()) {
            input.deliver(message);
        }
    }

    /// The workspace of the session under `key`.
    pub(crate) fn session(&self, key: &SessionKey) -> Option<Workspace> {
        self.sessions()
            .into_iter()
            .find(|workspace| workspace.key().as_ref() == Some(key))
    }

    /// The connection tree marks the connection as connecting, or not.
    pub(crate) fn set_connecting(&self, key: &SessionKey, connecting: bool) {
        if let Some(tree) = self.imp().tree.borrow().as_ref() {
            tree.set_connecting(key, connecting);
        }
    }

    /// Let go of the tree and what it watches, as the window goes.
    pub(crate) fn shutdown(&self) {
        if let Some(tree) = self.imp().tree.take() {
            tree.shutdown();
        }
    }

    /// Hold `workspace`'s banners, its branch of the tree and its
    /// exports, and bring it to the front.
    pub(crate) fn add_session(&self, workspace: &Workspace) {
        let imp = self.imp();
        imp.sessions.borrow_mut().push(workspace.clone());
        imp.session_banners.add_child(workspace);
        let tree = imp.tree.borrow().clone();
        if let (Some(tree), Some(key), Some(view)) = (tree, workspace.key(), workspace.sidebar_view()) {
            tree.add_session(&key, &workspace.connection_name().unwrap_or_default(), &view);
        }
        if let (Some(jobs), Some(exports)) = (imp.export_jobs.borrow().as_ref(), workspace.exports()) {
            jobs.append(&exports.jobs());
        }
        self.set_front(workspace);
    }

    /// Let go of `workspace`, which has shut down. Another session comes
    /// to the front: the one whose tab is selected, else the newest.
    pub(crate) fn remove_session(&self, workspace: &Workspace, key: &SessionKey) {
        let imp = self.imp();
        imp.sessions.borrow_mut().retain(|held| held != workspace);
        if workspace.parent().is_some() {
            imp.session_banners.remove(workspace);
        }
        let tree = imp.tree.borrow().clone();
        if let Some(tree) = tree {
            tree.remove_session(key);
        }
        if let Some(jobs) = imp.export_jobs.borrow().as_ref() {
            prune_export_jobs(jobs, &self.sessions());
        }
        let was_front = imp.front.borrow().as_ref() == Some(workspace);
        if !was_front {
            return;
        }
        imp.front.replace(None);
        let next = imp
            .tab_view
            .selected_page()
            .and_then(|page| self.owner_of(&page))
            .map(|(workspace, _)| workspace)
            .or_else(|| self.sessions().last().cloned());
        if let Some(next) = next {
            self.set_front(&next);
        } else {
            self.emit_by_name::<()>("front-changed", &[]);
        }
    }

    /// Make `workspace` the one the window speaks for.
    pub(crate) fn set_front(&self, workspace: &Workspace) {
        let imp = self.imp();
        if imp.front.borrow().as_ref() == Some(workspace) {
            return;
        }
        let left = imp.front.replace(Some(workspace.clone()));
        if let Some(left) = left {
            left.detach();
        }
        imp.session_banners.set_visible_child(workspace);
        workspace.attach();
        self.emit_by_name::<()>("front-changed", &[]);
    }

    /// The tab in front changed. Its session comes to the front once the
    /// view's signal is over, since the session that selected the tab may
    /// still be handling the input that did.
    fn follow_selected_page(&self) {
        let shell = self.downgrade();
        glib::idle_add_local_once(move || {
            let Some(shell) = shell.upgrade() else {
                return;
            };
            let owner = shell
                .imp()
                .tab_view
                .selected_page()
                .and_then(|page| shell.owner_of(&page));
            if let Some((workspace, _)) = owner {
                shell.set_front(&workspace);
            }
        });
    }

    pub(crate) fn connect_front_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "front-changed",
            false,
            glib::closure_local!(move |shell: &Self| f(shell)),
        )
    }
}

/// Keep only the export lists of the sessions still held.
fn prune_export_jobs(jobs: &gio::ListStore, sessions: &[Workspace]) {
    let kept: Vec<gio::ListStore> = sessions
        .iter()
        .filter_map(|workspace| workspace.exports().map(|exports| exports.jobs()))
        .collect();
    let mut position = 0;
    while position < jobs.n_items() {
        let held = jobs
            .item(position)
            .and_downcast::<gio::ListStore>()
            .is_some_and(|list| kept.contains(&list));
        if held {
            position += 1;
        } else {
            jobs.remove(position);
        }
    }
}

/// `win.show-assistant`, which follows the column whoever opens it.
fn assistant_action(shell: &WorkspaceShell) -> gio::SimpleAction {
    let imp = shell.imp();
    let split = imp.assistant_split.get();
    let action = gio::SimpleAction::new_stateful(SHOW_ASSISTANT, None, &false.to_variant());
    let shown = split.downgrade();
    let focus = imp.assistant_pane.downgrade();
    action.connect_change_state(move |action, state| {
        let Some(show) = state.and_then(|state| state.get::<bool>()) else {
            return;
        };
        action.set_state(&show.to_variant());
        if let Some(split) = shown.upgrade() {
            split.set_show_sidebar(show);
        }
        if show && let Some(pane) = focus.upgrade() {
            pane.focus_composer();
        }
    });
    let followed = action.downgrade();
    split.connect_show_sidebar_notify(move |split| {
        if let Some(action) = followed.upgrade() {
            action.set_state(&split.shows_sidebar().to_variant());
        }
    });
    action
}

/// The main menu with the session's Safe Mode levels on top, as radio
/// items of the window's stateful `safe-mode` action.
fn with_safe_mode(menu: &gio::MenuModel) -> gio::Menu {
    let levels = gio::Menu::new();
    for level in tablepro_core::SafeModeLevel::ALL {
        let item = gio::MenuItem::new(Some(&crate::ui::safe_mode::label(level)), None);
        item.set_action_and_target_value(
            Some("win.safe-mode"),
            Some(&crate::ui::safe_mode::action_target(level).to_variant()),
        );
        levels.append_item(&item);
    }
    let section = gio::Menu::new();
    section.append_submenu(Some(&crate::i18n::gettext("Safe Mode")), &levels);
    let whole = gio::Menu::new();
    whole.append_section(None, &section);
    whole.append_section(None, menu);
    whole
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
