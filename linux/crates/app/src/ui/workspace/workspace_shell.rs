//! The part of the workspace a window has once: the two header bars,
//! the connection tree, the one tab view every session's tabs share, the
//! assistant's column and the toasts. Each session keeps its own
//! `Workspace`. The one whose tab is selected is `front`, and the header
//! bars, the banners, the assistant and the window's actions follow it.

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::BinExt;
use tablepro_core::DataModel;
use uuid::Uuid;

use super::health_banner::REVIEW_HOST_KEY;
use super::sidebar::ConnectionTree;
use super::workspace_shell_imp::{self as imp, ClosedTab, Departure, HeldSession};
use super::{CLOSED_TABS_CAPACITY, ClosedTabDescriptor, Workspace, WorkspaceInput};
use crate::application::AppServices;
use crate::i18n::{gettext, gettext_f};
use crate::runtime::{DeliverInput, InputSender};
use crate::ui::SessionWindowInput;
use crate::ui::a11y::describe_icon_button;
use crate::ui::shell::{PRIMARY_MENU, TAB_OVERVIEW_MENU, app_menu, primary_menu_button};

/// The window action that shows and hides the sidebar, as GNOME Files
/// names it.
pub(super) const SHOW_SIDEBAR: &str = "show-sidebar";

const TABLES: &str = "tables";
const FAVORITES: &str = "favorites";

/// The window action that shows and hides the assistant's column.
pub(super) const SHOW_ASSISTANT: &str = "show-assistant";

type FavoritesRead = Result<
    Option<Result<Vec<tablepro_storage::saved_queries::SavedQuery>, tablepro_storage::StorageError>>,
    tablepro_session::runtime::TaskFailure,
>;

glib::wrapper! {
    pub struct WorkspaceShell(ObjectSubclass<imp::WorkspaceShell>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

/// Run as the shell is built, so its buttons are named before any
/// window holds it.
pub(super) fn describe_buttons(shell: &WorkspaceShell) {
    let imp = shell.imp();
    describe_icon_button(&imp.table_search_toggle.get(), &gettext("Search"), None);
    describe_icon_button(
        &imp.refresh_tables_button.get(),
        &gettext("Refresh"),
        Some("win.refresh-tables"),
    );
    describe_icon_button(
        &imp.sidebar_toggle.get(),
        &gettext("Show Sidebar"),
        Some("win.show-sidebar"),
    );
    describe_icon_button(
        &imp.refresh_page_button.get(),
        &gettext("Refresh Tab"),
        Some("win.refresh-page"),
    );
    describe_icon_button(
        &imp.new_tab_button.get(),
        &gettext("New Query"),
        Some("win.new-editor-tab"),
    );
    describe_icon_button(&imp.tab_button.get(), &gettext("View Open Tabs"), None);
    describe_icon_button(
        &imp.assistant_toggle.get(),
        &gettext("Show the Assistant"),
        Some("win.show-assistant"),
    );
}

impl WorkspaceShell {
    /// Hand `input` to the window that holds the shell.
    pub(crate) fn tell_window(&self, input: SessionWindowInput) {
        if let Some(sender) = self.imp().sender.get() {
            sender.deliver(input);
        }
    }

    /// A shell for `window`, with what it needs beyond the template: the
    /// connection tree and the picker's actions its rows name, the main
    /// menu, the window's actions, the tab menu and the overview's new
    /// tab.
    pub(crate) fn new(
        window: &adw::ApplicationWindow,
        services: &AppServices,
        sender: InputSender<SessionWindowInput>,
    ) -> Self {
        let shell: Self = glib::Object::new();
        let imp = shell.imp();
        imp.window.set(Some(window));
        let tree = ConnectionTree::new(services.saved_connections.clone());
        let sidebar = gtk::Stack::new();
        sidebar.add_named(&tree.widget(), Some(TABLES));
        let favorites = super::sidebar::FavoritesPane::new(
            glib::clone!(
                #[weak]
                shell,
                move |sql| shell.open_favorite(sql)
            ),
            glib::clone!(
                #[weak]
                shell,
                move || shell.reload_favorites()
            ),
        );
        sidebar.add_named(&favorites.widget(), Some(FAVORITES));
        imp.sidebar_slot.set_child(Some(&sidebar));
        let _ = imp.sidebar_stack.set(sidebar);
        let _ = imp.favorites.set(favorites);
        let _ = imp.favorites_source.set((services.history(), services.tasks.clone()));
        imp.favorites_availability
            .replace(Some(tablepro_session::runtime::WatchForwarder::new(
                services.history().availability(),
                glib::clone!(
                    #[weak]
                    shell,
                    move |_| shell.follow_favorites()
                ),
                |future| {
                    glib::spawn_future_local(future);
                },
            )));
        imp.scope_toggle.connect_active_name_notify(glib::clone!(
            #[weak]
            shell,
            move |_| shell.on_scope_changed()
        ));
        tree.follow_search(&imp.table_search);
        let _ = imp.tree.set(tree);
        crate::ui::picker::install_picker_actions(&shell, services.saved_connections.clone(), sender.clone());
        let _ = imp.sender.set(sender);

        let app = window.application();
        let menu_button = primary_menu_button(app.as_ref());
        if let Some(menu) = app_menu(app.as_ref(), PRIMARY_MENU) {
            menu_button.set_menu_model(Some(&with_safe_mode(&menu)));
        }
        imp.sidebar_header.pack_end(&menu_button);

        super::workspace_actions::install(window, &shell);
        imp.history_gate
            .replace(Some(super::workspace_actions::spawn_history_gate(
                window,
                services.history().availability(),
            )));
        window.add_action(&gio::PropertyAction::new(
            SHOW_SIDEBAR,
            &imp.split_view.get(),
            "show-sidebar",
        ));
        follow_sidebar(&imp.split_view, &imp.sidebar_toggle);
        window.add_action(&assistant_action(&shell));
        imp.walk_hooks.replace(Some(shell.hook_recent_walk(window)));

        imp.tab_view
            .bind_property("n-pages", &imp.tab_stack.get(), "visible-child-name")
            .transform_to(|_, pages: i32| Some(if pages > 0 { "tabs" } else { "empty" }))
            .sync_create()
            .build();
        super::workspace_tab_view::keep_child_navigation_keys(&imp.tab_view);
        shell.connect_overview(app.as_ref());
        shell.connect_tab_menu();
        shell.connect_view();
        shell.connect_front_notify(Self::on_front_changed);
        shell.bind_front();
        shell.add_controller(crate::application::local_shortcut_controller(
            crate::application::ShortcutOwner::WorkspaceShell,
        ));
        shell.describe_front();

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
        let _ = imp.export_jobs.set(jobs);
        shell
    }

    /// The overview's new tab opens an editor on the session in front,
    /// and shows only while there is one. The overview selects the page
    /// it gets back.
    fn connect_overview(&self, app: Option<&gtk::Application>) {
        let overview = self.imp().tab_overview.get();
        if let Some(menu) = app_menu(app, TAB_OVERVIEW_MENU) {
            overview.set_secondary_menu(Some(&menu));
        }
        self.bind_property("front", &overview, "enable-new-tab")
            .transform_to(|_, front: Option<Workspace>| Some(front.is_some()))
            .sync_create()
            .build();
    }

    /// The overview's new tab opens an editor in the session in front.
    /// The typed handler hands the page back as libadwaita expects;
    /// returning it through a generic closure keeps an extra reference
    /// and the closed tab is never freed.
    fn follow_front_for_new_tabs(&self) {
        let imp = self.imp();
        let overview = imp.tab_overview.get();
        if let Some(handler) = imp.create_tab.take() {
            overview.disconnect(handler);
        }
        if let Some(factory) = self.front().and_then(|front| front.tab_factory()) {
            imp.create_tab
                .replace(Some(overview.connect_create_tab(move |_| factory.create_editor())));
        }
    }

    /// The tab menu closes pages of every session in the bar, each one
    /// through its own session's prompts. Close comes last, and no item
    /// says left or right, as the GNOME HIG asks.
    fn connect_tab_menu(&self) {
        let imp = self.imp();
        let group = gio::SimpleActionGroup::new();
        let menu_action = |name: &str, close: fn(&adw::TabView, &adw::TabPage)| {
            let action = gio::SimpleAction::new(name, None);
            let shell = self.downgrade();
            action.connect_activate(move |_, _| {
                let Some(shell) = shell.upgrade() else {
                    return;
                };
                let page = shell.imp().menu_target.borrow().clone();
                if let Some(page) = page {
                    close(&shell.imp().tab_view, &page);
                }
            });
            action
        };
        group.add_action(&menu_action("close-others", |view, page| view.close_other_pages(page)));
        group.add_action(&menu_action("close-after", |view, page| view.close_pages_after(page)));
        group.add_action(&menu_action("close", |view, page| view.close_page(page)));
        // The bar and the overview parent the menu's popover, and the view
        // is an ancestor of neither.
        self.insert_action_group("tab", Some(&group));
        let _ = imp.tab_actions.set(group);
        let target = self.downgrade();
        imp.tab_view.connect_setup_menu(move |view, page| {
            let Some(shell) = target.upgrade() else {
                return;
            };
            shell.imp().menu_target.replace(page.cloned());
            if let Some(page) = page {
                shell.dim_tab_menu(view, page);
            }
        });
        imp.tab_view.set_menu_model(Some(&tab_menu()));
    }

    /// Dim what would close nothing for `page`, whose menu opens.
    fn dim_tab_menu(&self, view: &adw::TabView, page: &adw::TabPage) {
        let Some(group) = self.imp().tab_actions.get() else {
            return;
        };
        let last = view.n_pages() - 1;
        for (name, enabled) in [
            ("close-others", last > 0),
            ("close-after", view.page_position(page) < last),
        ] {
            if let Some(action) = group.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                action.set_enabled(enabled);
            }
        }
    }

    /// Close every session's tabs, each through its own session's
    /// prompts.
    pub(super) fn close_all_tabs(&self) {
        let view = self.tab_view();
        // The selected page goes last, so the view does not select each
        // neighbour in turn and bring its session forward.
        if let Some(selected) = view.selected_page() {
            view.close_other_pages(&selected);
            view.close_page(&selected);
        }
    }

    fn connect_view(&self) {
        let view = self.imp().tab_view.get();
        let shell = self.downgrade();
        view.connect_selected_page_notify(move |_| {
            if let Some(shell) = shell.upgrade() {
                shell.follow_selected_page();
            }
        });
        // A tab never leaves its session's window (ADR 0028), and libadwaita has no way to decline the new window
        // it asks for here, so the tab comes back to this view: docs/toolkit-workarounds.md, "A tab dropped outside
        // every window".
        let shell = self.downgrade();
        view.connect_create_window(move |view| {
            if let Some(shell) = shell.upgrade() {
                shell.imp().declined_tear_out.set(true);
            }
            Some(view.clone())
        });
        let shell = self.downgrade();
        view.connect_page_attached(move |view, page, _| {
            let Some(shell) = shell.upgrade() else {
                return;
            };
            shell.tell_sharing();
            // A page appended here is not in its session's index yet, so
            // only a transfer counts.
            if !view.is_transferring_page() {
                return;
            }
            let declined = shell.imp().declined_tear_out.replace(false);
            if declined || shell.owner_of(page).is_none() {
                // libadwaita is still attaching it; the window's queue
                // moves it once that is done.
                shell.tell_window(SessionWindowInput::ReturnTab(page.downgrade().into()));
            } else {
                shell.take_departure(page);
            }
        });
        let shell = self.downgrade();
        view.connect_page_detached(move |view, page, position| {
            let Some(shell) = shell.upgrade() else {
                return;
            };
            shell.tell_sharing();
            if view.is_transferring_page() && shell.owner_of(page).is_some() {
                shell.imp().departure.replace(Some(Departure {
                    page: page.downgrade(),
                    position,
                }));
            }
        });
    }

    /// Where `page` stood before a drag took it out of this view, once.
    pub(crate) fn take_departure(&self, page: &adw::TabPage) -> Option<i32> {
        let mut departure = self.imp().departure.borrow_mut();
        let left = departure
            .as_ref()
            .filter(|left| left.page.upgrade().as_ref() == Some(page))?;
        let position = left.position;
        *departure = None;
        Some(position)
    }

    /// The header bars, the window's title and the actions that act on
    /// one session follow the session in front.
    fn bind_front(&self) {
        let imp = self.imp();
        let front = gtk::PropertyExpression::new(Self::static_type(), None::<&gtk::Expression>, "front");
        let of_front = |property: &str| gtk::PropertyExpression::new(Workspace::static_type(), Some(&front), property);
        let (title, icon) = (imp.window_title.get(), imp.connection_icon.get());
        let shows_icon = gtk::ClosureExpression::new::<bool>(
            [of_front("icon-name")],
            glib::closure!(|_: Option<glib::Object>, icon: Option<String>| icon.is_some()),
        );
        let mut watches = vec![
            of_front("title").bind(&title, "title", Some(self)),
            of_front("subtitle").bind(&title, "subtitle", Some(self)),
            of_front("icon-name").bind(&icon, "icon-name", Some(self)),
            shows_icon.bind(&icon, "visible", Some(self)),
            of_front("assistant-available").bind(&imp.assistant_toggle.get(), "visible", Some(self)),
        ];
        if let Some(window) = imp.window.upgrade() {
            watches.push(of_front("window-title").bind(&window, "title", Some(self)));
            for (name, property) in [
                (SHOW_ASSISTANT, "assistant-available"),
                (REVIEW_HOST_KEY, "can-review-host-key"),
                ("refresh-page", "can-refresh"),
            ] {
                if let Some(action) = window.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                    // Off until a session is in front to say.
                    action.set_enabled(false);
                    watches.push(of_front(property).bind(&action, "enabled", Some(self)));
                }
            }
        }
        imp.watches.replace(watches);
    }

    /// The session that shows `page`, with the tab's id.
    pub(crate) fn owner_of(&self, page: &adw::TabPage) -> Option<(Workspace, Uuid)> {
        self.imp()
            .sessions
            .borrow()
            .iter()
            .find_map(|held| held.workspace.tab_id(page).map(|id| (held.workspace.clone(), id)))
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

    /// The saved connections and the open sessions' tables, in the
    /// sidebar. `None` only for a shell not built by `new`.
    pub(crate) fn tree(&self) -> Option<ConnectionTree> {
        self.imp().tree.get().cloned()
    }

    /// The sessions the window holds, in the order they joined.
    pub(crate) fn sessions(&self) -> Vec<Workspace> {
        self.imp()
            .sessions
            .borrow()
            .iter()
            .map(|held| held.workspace.clone())
            .collect()
    }

    /// Hold `workspace`: its banners, its assistant, its exports and its
    /// branch of the tree. It comes to the front while no tab is on
    /// screen; otherwise the tab the user works in keeps the front until
    /// one of its own is selected.
    pub(crate) fn add_session(&self, workspace: &Workspace) {
        let imp = self.imp();
        let handlers = self.follow_session(workspace);
        imp.session_banners.add_child(workspace);
        imp.list_banners.add_child(&workspace.imp().list_banners.get());
        if let Some(pane) = workspace.assistant_pane() {
            imp.assistant_stack.add_child(&pane);
        }
        let jobs = workspace.exports().map(|exports| exports.jobs());
        if let (Some(all), Some(list)) = (imp.export_jobs.get(), jobs.as_ref()) {
            all.append(list);
        }
        if let (Some(tree), Some(key), Some(sidebar)) = (imp.tree.get(), workspace.key(), workspace.sidebar_view()) {
            tree.add_session(&key, &workspace.connection_name(), &sidebar);
        }
        imp.sessions.borrow_mut().push(HeldSession {
            workspace: workspace.clone(),
            handlers,
            jobs,
        });
        self.tell_sharing();
        if imp.tab_view.selected_page().is_none() {
            self.set_front(Some(workspace));
        }
    }

    /// What the shell hears from a session it holds.
    fn follow_session(&self, workspace: &Workspace) -> Vec<glib::SignalHandlerId> {
        let shell = self.downgrade();
        let saving = workspace.connect_saves_in_flight_changed(move |_, _| {
            if let Some(shell) = shell.upgrade() {
                shell.refresh_saving();
            }
        });
        let shell = self.downgrade();
        let renamed = workspace.connect_connection_name_notify(move |workspace| {
            if let Some(shell) = shell.upgrade()
                && shell.front().as_ref() == Some(workspace)
            {
                shell.describe_front();
            }
        });
        let shell = self.downgrade();
        let assistant = workspace.connect_assistant_available_notify(move |workspace| {
            if let Some(shell) = shell.upgrade()
                && shell.front().as_ref() == Some(workspace)
            {
                shell.sync_assistant_column();
            }
        });
        vec![saving, renamed, assistant]
    }

    /// Let go of `workspace`, before it shuts down. The session whose
    /// tab is selected stays in front, else the newest comes forward
    /// with the tab it was left on, before the leaving session's pages
    /// close and the view would pick a neighbour of theirs.
    pub(crate) fn remove_session(&self, workspace: &Workspace) {
        let imp = self.imp();
        let held = {
            let mut sessions = imp.sessions.borrow_mut();
            let Some(position) = sessions.iter().position(|held| &held.workspace == workspace) else {
                return;
            };
            sessions.remove(position)
        };
        for handler in held.handlers {
            workspace.disconnect(handler);
        }
        imp.closed_tabs
            .borrow_mut()
            .retain(|closed| closed.session.upgrade().is_some_and(|session| &session != workspace));
        let shown = imp
            .tab_view
            .selected_page()
            .and_then(|page| self.owner_of(&page))
            .map(|(owner, _)| owner);
        let next = shown.clone().or_else(|| self.sessions().last().cloned());
        if shown.is_none()
            && let Some(page) = next.as_ref().and_then(Workspace::some_page)
        {
            imp.tab_view.set_selected_page(&page);
        }
        self.set_front(next.as_ref());
        if holds_child(&imp.session_banners, workspace) {
            imp.session_banners.remove(workspace);
        }
        let banners = workspace.imp().list_banners.get();
        if holds_child(&imp.list_banners, &banners) {
            imp.list_banners.remove(&banners);
        }
        if let Some(pane) = workspace.assistant_pane()
            && holds_child(&imp.assistant_stack, &pane)
        {
            imp.assistant_stack.remove(&pane);
        }
        if let (Some(all), Some(list)) = (imp.export_jobs.get(), held.jobs.as_ref())
            && let Some(position) = all.find(list)
        {
            all.remove(position);
        }
        if let (Some(tree), Some(key)) = (imp.tree.get(), workspace.key()) {
            tree.remove_session(&key);
        }
        if let Some(front) = self.front() {
            front.read(super::WorkspaceModel::select_in_tree);
        }
        self.tell_sharing();
        self.refresh_saving();
    }

    /// Bring `workspace` forward with the tab it was left on, or with a
    /// new SQL editor when it has none open.
    pub(crate) fn show_session(&self, workspace: &Workspace) {
        if !self.holds(workspace) {
            return;
        }
        match workspace.some_page() {
            Some(page) => self.imp().tab_view.set_selected_page(&page),
            None => {
                if let Some(input) = workspace.sender() {
                    input.deliver(WorkspaceInput::NewEditorTab);
                }
            }
        }
        self.set_front(Some(workspace));
    }

    fn holds(&self, workspace: &Workspace) -> bool {
        self.imp()
            .sessions
            .borrow()
            .iter()
            .any(|held| &held.workspace == workspace)
    }

    /// The tab on screen changed: its session comes to the front. With
    /// no tab the front stays where it was.
    pub(super) fn follow_selected_page(&self) {
        let Some(page) = self.imp().tab_view.selected_page() else {
            return;
        };
        self.note_shown_tab();
        if let Some((owner, _)) = self.owner_of(&page) {
            self.set_front(Some(&owner));
        }
    }

    fn set_front(&self, workspace: Option<&Workspace>) {
        let imp = self.imp();
        if imp.front.borrow().as_ref() == workspace {
            return;
        }
        imp.front.replace(workspace.cloned());
        self.notify_front();
    }

    fn on_scope_changed(&self) {
        let imp = self.imp();
        let favorites = imp.scope_toggle.active_name().as_deref() == Some(FAVORITES);
        if let Some(stack) = imp.sidebar_stack.get() {
            stack.set_visible_child_name(if favorites { FAVORITES } else { TABLES });
        }
        // The search reads connections and tables, which this scope does not list.
        imp.table_search_toggle.set_visible(!favorites);
        imp.refresh_tables_button.set_visible(!favorites);
        if favorites {
            imp.table_search_bar.set_search_mode(false);
            imp.table_search_bar.set_key_capture_widget(None::<&gtk::Widget>);
        } else {
            imp.table_search_bar.set_key_capture_widget(Some(&*imp.sidebar_root));
        }
        self.reload_favorites();
    }

    fn follow_favorites(&self) {
        let imp = self.imp();
        if imp.favorites_watch.borrow().is_none()
            && let Some((history, _)) = imp.favorites_source.get()
            && let Some(history) = history.store()
        {
            imp.favorites_watch
                .replace(Some(tablepro_session::runtime::WatchForwarder::new(
                    history.saved_queries().changes(),
                    glib::clone!(
                        #[weak(rename_to = shell)]
                        self,
                        move |_| shell.reload_favorites()
                    ),
                    |future| {
                        glib::spawn_future_local(future);
                    },
                )));
        }
        self.reload_favorites();
    }

    pub(crate) fn reload_favorites(&self) {
        let imp = self.imp();
        let generation = imp.favorites_generation.get().wrapping_add(1);
        imp.favorites_generation.set(generation);
        let connection = self.front().and_then(|front| front.connection_id());
        let (Some(pane), Some((history, tasks))) = (imp.favorites.get(), imp.favorites_source.get()) else {
            return;
        };
        if imp.favorites_connection.replace(connection) != connection {
            pane.clear();
        }
        if imp.scope_toggle.active_name().as_deref() != Some(FAVORITES) {
            return;
        }
        let Some(connection) = connection else {
            pane.no_connection();
            return;
        };
        pane.loading();
        let ready = history.ready_store();
        crate::runtime::spawn_and_deliver(
            tasks,
            async move {
                let history = ready.await?;
                Some(history.saved_queries().list(Some(connection)).await)
            },
            glib::clone!(
                #[weak(rename_to = shell)]
                self,
                move |listed| shell.favorites_arrived(generation, connection, listed)
            ),
        );
    }

    fn favorites_arrived(&self, generation: u64, connection: Uuid, listed: FavoritesRead) {
        if self.imp().favorites_generation.get() != generation
            || self.front().and_then(|front| front.connection_id()) != Some(connection)
        {
            return;
        }
        let Some(pane) = self.imp().favorites.get() else {
            return;
        };
        match listed {
            Ok(Some(Ok(favorites))) => pane.show(favorites),
            Ok(None) => pane.unavailable(),
            other => {
                tracing::warn!(?other, "could not read favorites");
                pane.failed();
            }
        }
    }

    fn open_favorite(&self, sql: String) {
        if let Some(sender) = self.front().and_then(|front| front.sender()) {
            sender.deliver(super::WorkspaceInput::OpenHistoryQuery(sql));
        }
    }

    fn on_front_changed(&self) {
        let imp = self.imp();
        if let Some(front) = self.front() {
            if holds_child(&imp.session_banners, &front) {
                imp.session_banners.set_visible_child(&front);
            }
            let banners = front.imp().list_banners.get();
            if holds_child(&imp.list_banners, &banners) {
                imp.list_banners.set_visible_child(&banners);
            }
            if let Some(pane) = front.assistant_pane()
                && holds_child(&imp.assistant_stack, &pane)
            {
                imp.assistant_stack.set_visible_child(&pane);
            }
        }
        self.describe_front();
        self.reload_favorites();
        self.sync_assistant_column();
        self.follow_front_for_new_tabs();
        // A front with a tab selected says which row it shows itself.
        if imp.tab_view.selected_page().is_none()
            && let Some(tree) = imp.tree.get()
        {
            tree.select(None, None);
        }
    }

    /// The page with no tab open speaks of what the front's engine
    /// holds, and the sidebar's Refresh names the connection it reads.
    fn describe_front(&self) {
        let imp = self.imp();
        let front = self.front();
        let (title, description, editor) = match front.as_ref().and_then(Workspace::data_model) {
            Some(DataModel::KeyValue) => (
                gettext("Select a Key"),
                gettext("Choose a key in the sidebar or open the editor."),
                gettext("Open Editor"),
            ),
            Some(DataModel::Document) => (
                gettext("Select a Collection"),
                gettext("Choose a collection in the sidebar or open the editor."),
                gettext("Open Editor"),
            ),
            Some(DataModel::Relational) | None => (
                gettext("Select a Table"),
                gettext("Choose a table in the sidebar or open the SQL editor."),
                gettext("Open SQL Editor"),
            ),
        };
        imp.empty_page.set_title(&title);
        imp.empty_page.set_description(Some(&description));
        imp.empty_editor_button.set_label(&editor);
        let refresh = front.map_or_else(
            || gettext("Refresh"),
            |front| gettext_f("Refresh “{connection}”", &[("connection", &front.connection_name())]),
        );
        describe_icon_button(&imp.refresh_tables_button.get(), &refresh, Some("win.refresh-tables"));
    }

    /// A front with no assistant leaves no column open.
    fn sync_assistant_column(&self) {
        if self.front().is_some_and(|front| !front.assistant_available()) {
            self.imp().assistant_split.set_show_sidebar(false);
        }
    }

    /// Open the assistant's column, for a statement an editor asked
    /// about.
    pub(super) fn reveal_assistant(&self) {
        self.imp().assistant_split.set_show_sidebar(true);
    }

    /// The header's spinner shows while any session is saving.
    fn refresh_saving(&self) {
        let saving = self
            .imp()
            .sessions
            .borrow()
            .iter()
            .any(|held| held.workspace.is_saving());
        self.imp().row_op_spinner.set_visible(saving);
    }

    /// Each session titles its tabs again once it has read whether
    /// another session's tab shares the bar.
    fn tell_sharing(&self) {
        for workspace in self.sessions() {
            if let Some(input) = workspace.sender() {
                input.deliver(WorkspaceInput::SharesBar);
            }
        }
    }

    /// Whether a session other than `workspace` has a tab in the bar.
    pub(super) fn others_have_tabs(&self, workspace: &Workspace) -> bool {
        self.imp()
            .sessions
            .borrow()
            .iter()
            .any(|held| &held.workspace != workspace && held.workspace.has_tabs())
    }

    /// Keep a tab `session` closed for Ctrl+Shift+T, which reopens the
    /// tab closed last whichever session it was in.
    pub(super) fn remember_closed_tab(&self, session: &Workspace, tab: ClosedTabDescriptor) {
        let mut closed = self.imp().closed_tabs.borrow_mut();
        if closed.len() == CLOSED_TABS_CAPACITY {
            closed.pop_front();
        }
        closed.push_back(ClosedTab {
            session: session.downgrade(),
            tab,
        });
    }

    /// Open the tab closed last again, in the session it was closed in.
    pub(super) fn reopen_closed_tab(&self) {
        let reopened = loop {
            let Some(closed) = self.imp().closed_tabs.borrow_mut().pop_back() else {
                break None;
            };
            if let Some(session) = closed.session.upgrade()
                && self.holds(&session)
                && let Some(input) = session.sender()
            {
                break Some((input, closed.tab));
            }
        };
        match reopened {
            Some((input, tab)) => input.deliver(WorkspaceInput::ReopenClosedTab(tab)),
            // Without a toast the shortcut would read as broken.
            None => self
                .toast_overlay()
                .add_toast(crate::ui::plain_toast(&gettext("No recently closed tab"))),
        }
    }

    /// Let go of the tree and what it watches, and take the shell's
    /// actions off the window: `show-sidebar` holds the split view, and
    /// with it every tab, for as long as the window has it. The window
    /// names itself again from here on.
    pub(crate) fn shutdown(&self) {
        let imp = self.imp();
        imp.favorites_generation
            .set(imp.favorites_generation.get().wrapping_add(1));
        imp.favorites_watch.take();
        imp.favorites_availability.take();
        for watch in imp.watches.take() {
            watch.unwatch();
        }
        if let Some(handler) = imp.create_tab.take() {
            imp.tab_overview.disconnect(handler);
        }
        if let Some(gate) = imp.history_gate.take() {
            gate.abort();
        }
        if let Some(tree) = imp.tree.get() {
            tree.shutdown();
        }
        for held in imp.sessions.take() {
            for handler in held.handlers {
                held.workspace.disconnect(handler);
            }
        }
        imp.closed_tabs.borrow_mut().clear();
        imp.recent_walk.take();
        if let Some(hooks) = imp.walk_hooks.take() {
            hooks.release();
        }
        if let Some(window) = imp.window.upgrade() {
            window.remove_action(SHOW_SIDEBAR);
            window.remove_action(SHOW_ASSISTANT);
            super::workspace_actions::remove(&window);
        }
    }
}

/// Whether `child` is one of `stack`'s pages: GTK logs a critical for a
/// stack asked to show or drop a widget it does not hold.
fn holds_child(stack: &gtk::Stack, child: &impl IsA<gtk::Widget>) -> bool {
    child.parent().as_ref() == Some(stack.upcast_ref::<gtk::Widget>())
}

/// `win.show-assistant`, which follows the column whoever opens it, and
/// puts the focus in the front's composer.
fn assistant_action(shell: &WorkspaceShell) -> gio::SimpleAction {
    let split = shell.imp().assistant_split.get();
    let action = gio::SimpleAction::new_stateful(SHOW_ASSISTANT, None, &false.to_variant());
    let shown = split.downgrade();
    let focus = shell.downgrade();
    action.connect_change_state(move |action, state| {
        let Some(show) = state.and_then(|state| state.get::<bool>()) else {
            return;
        };
        action.set_state(&show.to_variant());
        if let Some(split) = shown.upgrade() {
            split.set_show_sidebar(show);
        }
        if show
            && let Some(pane) = focus
                .upgrade()
                .and_then(|shell| shell.front())
                .and_then(|front| front.assistant_pane())
        {
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

fn tab_menu() -> gio::Menu {
    let others = gio::Menu::new();
    others.append(Some(&gettext("Close _Other Tabs")), Some("tab.close-others"));
    others.append(Some(&gettext("Close Tabs _After This One")), Some("tab.close-after"));
    let close = gio::Menu::new();
    close.append(Some(&gettext("_Close")), Some("tab.close"));
    let menu = gio::Menu::new();
    menu.append_section(None, &others);
    menu.append_section(None, &close);
    menu
}

/// The main menu with the session's Safe Mode levels on top, as radio
/// items of the window's stateful `safe-mode` action.
fn with_safe_mode(menu: &gio::MenuModel) -> gio::Menu {
    let levels = gio::Menu::new();
    for level in tablepro_core::SafeModeLevel::ALL {
        let item = gio::MenuItem::new(Some(&crate::ui::safe_mode::menu_label(level)), None);
        item.set_action_and_target_value(
            Some("win.safe-mode"),
            Some(&crate::ui::safe_mode::action_target(level).to_variant()),
        );
        levels.append_item(&item);
    }
    let section = gio::Menu::new();
    section.append_submenu(Some(&gettext("_Safe Mode")), &levels);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RESOURCE_BASE_PATH;
    use crate::test_support::assert_access_keys;

    #[gtk4::test]
    fn favorites_reject_old_reads_and_clear_rows_when_the_front_changes() {
        use crate::ui::session_window::tests::TestWindow;
        use tablepro_storage::saved_queries::SavedQuery;
        let test = TestWindow::connected("FavoritesRequests");
        let shell = test.window.shell().expect("shell");
        shell.imp().scope_toggle.set_active_name(Some(FAVORITES));
        let connection = test.workspace().connection_id().expect("connection");
        let old = shell.imp().favorites_generation.get();
        shell.reload_favorites();
        let current = shell.imp().favorites_generation.get();
        let saved = SavedQuery {
            id: 1,
            name: "Current".to_owned(),
            query: "SELECT 1".to_owned(),
            connection_id: connection,
            connection_name: "Database".to_owned(),
            created_at: std::time::SystemTime::UNIX_EPOCH,
            updated_at: std::time::SystemTime::UNIX_EPOCH,
        };
        shell.favorites_arrived(current, connection, Ok(Some(Ok(vec![saved.clone()]))));
        let pane = shell.imp().favorites.get().expect("pane");
        shell.favorites_arrived(old, connection, Ok(Some(Ok(vec![]))));
        assert_eq!(pane.names(), ["Current"]);
        shell.favorites_arrived(current, Uuid::new_v4(), Ok(Some(Ok(vec![]))));
        assert_eq!(pane.names(), ["Current"]);
        shell.set_front(None);
        assert!(pane.names().is_empty());
        shell.favorites_arrived(current, connection, Ok(Some(Ok(vec![saved]))));
        assert!(pane.names().is_empty());
    }

    #[gtk4::test]
    fn the_tab_menu_and_the_main_menu_give_each_item_its_own_access_key() {
        crate::register_test_resources();
        let builder = gtk::Builder::from_resource(&format!("{RESOURCE_BASE_PATH}/gtk/menus.ui"));
        let main: gio::MenuModel = builder.object(PRIMARY_MENU).expect("the main menu");

        assert_access_keys(&tab_menu());
        assert_access_keys(&with_safe_mode(&main));
    }
}
