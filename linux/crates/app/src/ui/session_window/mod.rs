//! A window of connection sessions. It holds two lists, the sessions it
//! adopted and the connects it runs, and shows what they call for: the
//! shell while it holds a session, the failed page when a connect failed
//! with nothing else to show, the connecting page for its first connect,
//! and the picker otherwise. Every connect, wherever it starts, runs
//! beside the others and its session joins the shell, each with its own
//! workspace. A disconnect tears one session's workspace down in order.
//! A workspace never moves to another session.

mod application_notification_sink;
mod connect_failed_page;
mod connect_failure_details;
mod connect_failure_view;
mod connect_flow;
mod connecting_page;
mod connections;
mod file_location_dialog;
mod imp;
mod launch_notice;
mod locate_file;
mod notification_request;
mod notification_sink;
mod notifications;
mod picker_page;
mod resolve_file_identity;
mod secret_retry;
mod session_page;
mod session_restore;
mod session_teardown;
mod session_window_command;
mod session_window_input;
mod sibling_sessions;
#[cfg(test)]
pub(crate) mod tests;
mod window_actions;
mod work_notifier;

use std::rc::Rc;
use std::sync::Arc;

use futures::FutureExt;
use futures::future::BoxFuture;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::AdwApplicationWindowExt;
use tokio_util::sync::CancellationToken;

use tablepro_core::{DatabaseDriver, DriverError, SafeModeLevel, TransportClass};
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::registry::FileIdentity;
use tablepro_session::runtime::ProcessHold;
use tablepro_session::{
    ClaimError, ConnectError, ConnectIntent, ConnectSource, MonitorSignal, PendingSession, RequestTarget, Session,
    SessionClaim, SessionKey,
};
use tablepro_storage::{CredentialDemand, SavedConnection};

pub(super) use self::connect_failed_page::ConnectFailedPage;
use self::connect_failure_view::ConnectFailureView;
pub(super) use self::connecting_page::ConnectingPage;
use self::file_location_dialog::FileCheck;
pub(crate) use self::launch_notice::LaunchNotice;
pub(super) use self::picker_page::PickerPage;
use self::resolve_file_identity::{FileResolveError, FileTarget, ResolvedFile, resolve_file_blocking};
use self::session_page::{FailedConnect, OpenSession, PendingConnect, SessionPage, source_key};
use self::session_window_command::{AttemptError, ConnectFailure, Connected, SessionWindowCommand};
pub(crate) use self::session_window_input::SessionWindowInput;
use crate::application::{AppServices, WindowHost, WindowLaunch};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::session_context::SessionContext;
use crate::ui::connect_dialog::{ConnectDialogMode, ConnectSubmission};
use crate::ui::welcome_view::WelcomeView;
use crate::ui::workspace::{Workspace, WorkspaceInit, WorkspaceInput, WorkspaceShell};
use crate::workspace::{
    ApplicationInhibit, CloseDecision, CloseGuards, CloseReason, InhibitReason, WindowInhibitor, WorkspaceHandle,
};

glib::wrapper! {
    pub struct SessionWindow(ObjectSubclass<imp::SessionWindow>)
        @extends adw::ApplicationWindow, gtk::ApplicationWindow, gtk::Window, gtk::Widget,
        @implements gio::ActionGroup, gio::ActionMap, gtk::Accessible, gtk::Buildable,
            gtk::ConstraintTarget, gtk::Native, gtk::Root, gtk::ShortcutManager;
}

/// What the application hands each window it opens.
pub struct SessionWindowInit {
    pub services: Rc<AppServices>,
    pub host: Rc<dyn WindowHost>,
    pub launch: WindowLaunch,
}

/// What a window keeps from its init for as long as it is open.
pub(crate) struct WindowState {
    services: Rc<AppServices>,
    /// Reaches the application's other windows.
    host: Rc<dyn WindowHost>,
    context: Rc<SessionContext>,
}

impl Default for SessionWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionWindow {
    pub fn new() -> Self {
        glib::Object::new()
    }

    /// Start the window on `init.launch`. Called once the window is
    /// added to the application, which gives it the id its sessions are
    /// claimed under.
    pub fn start(&self, init: SessionWindowInit) {
        let SessionWindowInit { services, host, launch } = init;
        let imp = self.imp();
        let (context, prompts) = services.window_context();
        let (input, receiver) = crate::runtime::input_queue::<SessionWindowInput>();
        let _ = imp.input.set(input.clone());
        let (tasks, hold) = (services.tasks.clone(), services.hold());
        imp.pump.replace(Some(crate::runtime::pump_inputs_with_leftovers(
            self,
            receiver,
            |window, message| window.handle_input(message),
            move |message| {
                if let Some(pending) = unadopted(message) {
                    discard_pending(pending, &tasks, &*hold);
                }
            },
        )));
        if crate::config::profile() == crate::config::Profile::Development {
            self.add_css_class("devel");
        }
        crate::ui::window_geometry::restore(self.upcast_ref(), &services.settings);
        window_actions::install(self.upcast_ref(), &input);
        self.install_notifier(&input);
        imp.prompt_presenter
            .replace(Some(crate::ui::credential_prompt::CredentialPromptPresenter::start(
                prompts, self,
            )));

        let _ = imp.close_guards.set(self.close_guards_for_window());
        imp.inhibitor
            .replace(Some(WindowInhibitor::new(ApplicationInhibit::new(self))));

        let list = services.saved_connections.clone();
        let welcome = WelcomeView::new(list.clone(), Some(services.tasks.clone()));
        crate::ui::picker::install_picker_actions(&welcome, list.clone(), input.clone());
        let picker = PickerPage::new(&welcome, self.application().as_ref());
        let searching = welcome.downgrade();
        picker.search_entry().connect_search_changed(move |entry| {
            if let Some(welcome) = searching.upgrade() {
                welcome.set_search(&entry.text());
            }
        });
        let connecting = welcome.downgrade();
        picker.search_entry().connect_activate(move |entry| {
            if let Some(welcome) = connecting.upgrade() {
                // Enter can come before search-changed, which waits for typing to pause.
                welcome.set_search(&entry.text());
                welcome.activate_first();
            }
        });
        let reset_input = input.clone();
        picker
            .banner()
            .connect_button_clicked(move |_| reset_input.deliver(SessionWindowInput::ResetConnectionList));
        let window = self.downgrade();
        imp.list_observer.set(Some(list.connect_state_changed(move |_| {
            if let Some(window) = window.upgrade() {
                window.show_connection_list_banner();
            }
        })));
        imp.welcome.replace(Some(welcome));
        let _ = imp.picker.set(picker);
        let _ = imp.state.set(WindowState {
            services,
            host,
            context,
        });

        self.render();
        self.show_connection_list_banner();
        input.deliver(SessionWindowInput::LoadConnections);
        self.open_launch(launch, &input);
    }

    fn open_launch(&self, launch: WindowLaunch, input: &InputSender<SessionWindowInput>) {
        let imp = self.imp();
        match launch {
            WindowLaunch::Picker => {}
            WindowLaunch::Connect(saved) => input.deliver(SessionWindowInput::OpenSaved(saved)),
            WindowLaunch::OpenFile(file) => {
                imp.opening_file.set(true);
                imp.opened_for_file.set(true);
                input.deliver(SessionWindowInput::OpenFile(file));
            }
            // Every recorded session connects at once, beside the others.
            WindowLaunch::Restore(keys) => {
                for key in &keys {
                    input.deliver(SessionWindowInput::Restore(key.clone()));
                }
                imp.restoring.replace(keys);
            }
        }
    }

    /// The banner over the picker that says the list cannot be read.
    #[cfg(test)]
    pub(crate) fn connection_list_banner(&self) -> Option<adw::Banner> {
        self.imp().picker.get().map(PickerPage::banner)
    }

    #[cfg(test)]
    pub(crate) fn picker_search(&self) -> Option<(gtk4::SearchBar, gtk4::SearchEntry)> {
        self.imp()
            .picker
            .get()
            .map(|picker| (picker.search_bar(), picker.search_entry()))
    }

    #[cfg(test)]
    pub(crate) fn manage_tags(&self) -> Option<std::rc::Rc<crate::ui::tags::ManageTagsDialog>> {
        self.imp().manage_tags.borrow().clone()
    }

    /// What the window's actions, pages and background work send it.
    pub(crate) fn input(&self) -> Option<InputSender<SessionWindowInput>> {
        self.imp().input.get().cloned()
    }

    pub(crate) fn send(&self, message: SessionWindowInput) {
        if let Some(input) = self.imp().input.get() {
            input.deliver(message);
        }
    }

    /// On the picker with nothing under way, so a file handed to the
    /// application can open here.
    pub(crate) fn is_idle(&self) -> bool {
        let imp = self.imp();
        self.page() == SessionPage::Picker
            && !imp.opening_file.get()
            && !imp.dialog_opening.get()
            && imp.dialog.try_borrow().is_ok_and(|dialog| dialog.is_none())
    }

    /// Whether the window shows the session under `key` or connects it.
    /// A failed connect's claim is not a session to reopen.
    pub(crate) fn keeps_session(&self, key: &SessionKey) -> bool {
        self.holds_session(key) || self.is_connecting(key)
    }

    /// Whether the window holds logout back now, for its unsaved
    /// changes or for an export a workspace is writing.
    pub(crate) fn is_inhibiting(&self) -> bool {
        let exporting = self
            .workspaces()
            .iter()
            .filter_map(Workspace::exports)
            .any(|exports| exports.is_inhibiting());
        exporting
            || self
                .imp()
                .inhibitor
                .borrow()
                .as_ref()
                .is_some_and(WindowInhibitor::is_held)
    }

    /// A test session has no session manager to grant an inhibition.
    #[cfg(test)]
    pub(crate) fn set_inhibitor(&self, inhibitor: WindowInhibitor) {
        self.imp().inhibitor.replace(Some(inhibitor));
    }

    /// Stop the window's input and close what it still holds: its
    /// sessions and its connects. Runs once, from the application as the
    /// window goes, or from dispose.
    pub fn shutdown(&self) {
        let imp = self.imp();
        if imp.shut_down.replace(true) {
            return;
        }
        if let Some(pump) = imp.pump.take() {
            pump.abort();
        }
        if let Some(notifier) = imp.notifier.take() {
            notifier.withdraw_all();
        }
        if let Some(presenter) = imp.prompt_presenter.take() {
            presenter.abort();
        }
        self.release_session();
        drop(imp.dialog.take());
        if let Some(welcome) = imp.welcome.take() {
            welcome.shutdown();
        }
        if let (Some(observer), Some(state)) = (imp.list_observer.take(), imp.state.get()) {
            state.services.saved_connections.disconnect_state_changed(observer);
        }
        drop(imp.inhibitor.take());
    }

    fn state(&self) -> Option<&WindowState> {
        self.imp().state.get()
    }

    fn close_guards(&self) -> Option<&Rc<CloseGuards>> {
        self.imp().close_guards.get()
    }

    /// What the window shows, from what it holds.
    fn page(&self) -> SessionPage {
        let imp = self.imp();
        if imp.sessions.try_borrow().is_ok_and(|sessions| !sessions.is_empty()) {
            return SessionPage::Shell;
        }
        if imp.failed.try_borrow().is_ok_and(|failed| failed.is_some()) {
            return SessionPage::Failed;
        }
        match imp
            .connects
            .try_borrow()
            .ok()
            .and_then(|connects| connects.first().map(|pending| pending.id))
        {
            Some(id) => SessionPage::Connecting(id),
            None => SessionPage::Picker,
        }
    }

    fn holds_session(&self, key: &SessionKey) -> bool {
        self.imp()
            .sessions
            .try_borrow()
            .is_ok_and(|sessions| sessions.iter().any(|open| open.claim.key() == key))
    }

    fn is_connecting(&self, key: &SessionKey) -> bool {
        self.imp()
            .connects
            .try_borrow()
            .is_ok_and(|connects| connects.iter().any(|pending| pending.claim.key() == key))
    }

    /// The workspace of the session in front: the one whose tab is on
    /// screen.
    pub(crate) fn workspace(&self) -> Option<Workspace> {
        self.shell()?.front()
    }

    /// The workspace of every session the window holds.
    pub(crate) fn workspaces(&self) -> Vec<Workspace> {
        self.imp().sessions.try_borrow().map_or_else(
            |_| Vec::new(),
            |sessions| sessions.iter().map(|open| open.workspace.clone()).collect(),
        )
    }

    /// The workspace that holds tab `tab`.
    pub(crate) fn workspace_with_tab(&self, tab: uuid::Uuid) -> Option<Workspace> {
        self.workspaces()
            .into_iter()
            .find(|workspace| workspace.open_tabs().is_some_and(|tabs| tabs.contains(&tab)))
    }

    /// The window's shell, while it holds a session.
    pub(crate) fn shell(&self) -> Option<WorkspaceShell> {
        self.imp().shell.try_borrow().ok()?.clone()
    }

    /// The workspace of the session under `key`.
    fn session_workspace(&self, key: &SessionKey) -> Option<Workspace> {
        let sessions = self.imp().sessions.try_borrow().ok()?;
        sessions
            .iter()
            .find(|open| open.claim.key() == key)
            .map(|open| open.workspace.clone())
    }

    /// The key and session of the session in front.
    pub(super) fn front_session(&self) -> Option<(SessionKey, Arc<Session>)> {
        let front = self.workspace()?;
        let sessions = self.imp().sessions.try_borrow().ok()?;
        sessions
            .iter()
            .find(|open| open.workspace == front)
            .map(|open| (open.claim.key().clone(), open.session.clone()))
    }

    /// The shell for the window's first session, which the later ones
    /// join. Its tree hears the connects and failures the window already
    /// has.
    fn new_shell(&self, state: &WindowState, input: &InputSender<SessionWindowInput>) -> WorkspaceShell {
        let shell = WorkspaceShell::new(self.upcast_ref(), &state.services, input.clone());
        let front = input.clone();
        shell.connect_notify_local(Some("front"), move |_, _| {
            front.deliver(SessionWindowInput::FrontChanged);
        });
        self.imp().shell.replace(Some(shell.clone()));
        self.sync_tree();
        if let Some(tree) = shell.tree() {
            for (key, (source, failure)) in self.imp().failures.borrow().iter() {
                tree.set_failure(key, Some((&source_name(source), failure.message.as_str())));
            }
        }
        shell
    }

    /// Every session's, for the window's own close.
    fn workspace_handles(&self) -> Vec<WorkspaceHandle> {
        self.workspaces().iter().filter_map(Workspace::prompt_handle).collect()
    }

    /// Whether any session has something to lose or a save running, read
    /// from the sessions whenever one says it changed.
    fn refresh_dirty(&self) {
        let workspaces = self.workspaces();
        let imp = self.imp();
        imp.dirty.set(workspaces.iter().any(Workspace::is_dirty));
        let saving = workspaces.iter().any(Workspace::is_saving);
        if imp.saving.replace(saving) != saving {
            self.notify_saving();
        }
        self.refresh_inhibitor();
    }

    fn handle_input(&self, message: SessionWindowInput) {
        match message {
            SessionWindowInput::OpenSaved(saved) => self.on_open_saved(*saved),
            SessionWindowInput::OpenFile(file) => self.on_open_file(file),
            SessionWindowInput::FileResolved(resolved) => self.on_file_resolved(*resolved),
            SessionWindowInput::Restore(key) => self.on_restore(key),
            SessionWindowInput::RestoreSaved { id, saved } => self.on_restore_saved(id, saved.map(|saved| *saved)),
            SessionWindowInput::RestoreUnread(key) => self.end_restore(&key),
            SessionWindowInput::OpenConnectDialog => {
                self.present_connect_dialog(ConnectDialogMode::Create, None, None);
            }
            SessionWindowInput::ConnectFromDialog(submission) => self.on_connect_from_dialog(*submission),
            SessionWindowInput::DialogClosed => drop(self.imp().dialog.take()),
            SessionWindowInput::CancelConnect => self.on_cancel_connect(),
            SessionWindowInput::StopConnecting(key) => self.stop_connecting(&key),
            SessionWindowInput::RetryConnect => {
                if let Some(key) = self.failed_key() {
                    self.on_retry_connect(&key);
                }
            }
            SessionWindowInput::RetryWithNewSecret(kind) => {
                if let Some(key) = self.failed_key() {
                    self.on_retry_with_new_secret(&key, kind);
                }
            }
            SessionWindowInput::EditConnection => {
                if let Some(key) = self.failed_key() {
                    self.on_edit_connection(&key);
                }
            }
            SessionWindowInput::Remedy { key, remedy } => self.on_remedy(key, remedy),
            SessionWindowInput::ShowConnectFailure(key) => self.on_show_connect_failure(key),
            SessionWindowInput::ForgetConnectFailure(key) => self.forget_failure(&key),
            SessionWindowInput::EditSavedConnection(id) => self.on_edit_saved_connection(id),
            SessionWindowInput::ConnectionSaved(id) => self.on_connection_saved(id),
            SessionWindowInput::Disconnect => self.on_disconnect_front(),
            SessionWindowInput::DisconnectSession(key) => self.on_disconnect(key),
            SessionWindowInput::ChooseDatabaseIn(key) => self.choose_database_in(key),
            SessionWindowInput::FollowDatabase { key, tab_id, database } => {
                self.follow_database(&key, tab_id, database);
            }
            SessionWindowInput::SessionTeardownApproved(key) => self.on_session_teardown_approved(&key),
            SessionWindowInput::ShowSession(key) => self.show_session(&key),
            SessionWindowInput::NewQueryIn(key) => self.deliver_to(&key, WorkspaceInput::NewEditorTab),
            SessionWindowInput::RefreshIn(key) => self.deliver_to(&key, WorkspaceInput::RefreshCatalog),
            SessionWindowInput::FrontChanged => self.sync_actions(),
            SessionWindowInput::ReturnForeignTab(page) => {
                if let Some(page) = page.upgrade() {
                    self.on_return_foreign_tab(&page);
                }
            }
            SessionWindowInput::SetSafeMode { key, level } => self.on_set_safe_mode(&key, level),
            SessionWindowInput::ReopenApproved(id) => self.on_reopen_approved(id),
            SessionWindowInput::CloseCurrent => self.on_close_current(),
            SessionWindowInput::Reconnect => {
                if let Some((_, session)) = self.front_session() {
                    session.signal(MonitorSignal::RetryNow);
                }
            }
            SessionWindowInput::ResetWorkspaceLayout => {
                if let Some(input) = self.workspace().and_then(|workspace| workspace.sender()) {
                    input.deliver(WorkspaceInput::ResetWorkspaceLayout);
                }
            }
            SessionWindowInput::CloseRequested(CloseReason::Quit(reply)) => {
                if let Some(guards) = self.close_guards() {
                    guards.request_window_close(self, move |decision: CloseDecision| {
                        // A quit that went away no longer needs the answer.
                        let _ = reply.send(decision);
                    });
                }
            }
            SessionWindowInput::DirtyChanged | SessionWindowInput::SavesInFlightChanged => self.refresh_dirty(),
            SessionWindowInput::WorkCompleted(work) => self.on_work_completed(work),
            SessionWindowInput::TabsChanged => self.on_tabs_changed(),
            SessionWindowInput::FocusTab(tab) => self.on_focus_tab(tab),
            SessionWindowInput::Command(command) => match *command {
                SessionWindowCommand::Attempt { id, result } => self.on_attempt(id, result),
            },
            SessionWindowInput::LocationChosen { id, choice } => self.on_location_chosen(id, choice),
            SessionWindowInput::FileLocated { id, path } => self.on_file_located(id, path),
            SessionWindowInput::LocatedSaved(located) => self.on_located_saved(*located),
            SessionWindowInput::LoadConnections => self.on_load_connections(),
            SessionWindowInput::ResetConnectionList => self.on_reset_connection_list(),
            SessionWindowInput::SecretDeleteFailed(id, options) => self.on_secret_delete_failed(id, options),
            SessionWindowInput::DeleteConnection(id) => self.on_delete_connection(id),
            SessionWindowInput::ConfirmDelete(id, options) => self.on_confirm_delete(id, options),
            SessionWindowInput::DuplicateConnection(id) => self.on_duplicate_connection(id),
            SessionWindowInput::SetConnectionColor(id, color) => self.on_set_connection_color(id, color),
            SessionWindowInput::SetConnectionGroup(id, group) => self.on_set_connection_group(id, group),
            SessionWindowInput::SetConnectionTag(id, tag, carried) => self.on_set_connection_tag(id, tag, carried),
            SessionWindowInput::CreateTag { name, color, on } => self.on_create_tag(name, color, on),
            SessionWindowInput::UpdateTag(tag) => self.on_update_tag(tag),
            SessionWindowInput::DeleteTag(id) => self.on_delete_tag(id),
            SessionWindowInput::ManageTags => self.on_manage_tags(),
            SessionWindowInput::ExportConnections => self.on_export_connections(),
            SessionWindowInput::ImportConnections => self.on_import_connections(),
            SessionWindowInput::ConnectionsFileRead { path, bytes } => self.on_connections_file_read(path, bytes),
            SessionWindowInput::ShowToast(message) => self.show_toast(&message),
        }
    }

    fn show_toast(&self, message: &str) {
        self.add_toast(crate::ui::plain_toast(message));
    }

    /// On the page on screen: a toast for a page left behind would never
    /// show.
    fn add_toast(&self, toast: adw::Toast) {
        #[cfg(test)]
        self.imp().toasts.borrow_mut().push(toast.clone());
        match self.imp().page_toasts.borrow().as_ref() {
            Some(overlay) => overlay.add_toast(toast),
            None => tracing::debug!(title = ?toast.title(), "a toast with no page to show it on"),
        }
    }

    /// Show the page the window's state calls for, building it only when
    /// it changed. What a page shows lives in the window's state, so the
    /// page left behind drops with nothing of its own.
    /// Show `failed` on the failed page, built again even when the page
    /// already shows another failure, so its remedies act on this one.
    fn show_failure(&self, failed: FailedConnect) {
        let imp = self.imp();
        imp.failed.replace(Some(failed));
        imp.shown.replace(None);
        self.render();
    }

    fn render(&self) {
        let page = self.page();
        if self.imp().shown.replace(Some(page)) != Some(page) {
            self.show_page(page);
        }
        self.sync_actions();
    }

    fn show_page(&self, page: SessionPage) {
        let imp = self.imp();
        let app = self.application();
        let (child, toasts, shown): (Option<gtk::Widget>, Option<adw::ToastOverlay>, ShownPage) = match page {
            SessionPage::Picker => {
                self.set_title(Some(&crate::i18n::gettext("TablePro")));
                let picker = imp.picker.get();
                (
                    picker.map(|picker| picker.clone().upcast()),
                    picker.map(PickerPage::toast_overlay),
                    ShownPage::Other,
                )
            }
            SessionPage::Connecting(id) => {
                let name = imp
                    .connects
                    .borrow()
                    .iter()
                    .find(|pending| pending.id == id)
                    .map(|pending| source_name(&pending.source))
                    .unwrap_or_default();
                let connecting = ConnectingPage::new(app.as_ref());
                let toasts = connecting.toast_overlay();
                (
                    Some(connecting.clone().upcast()),
                    Some(toasts),
                    ShownPage::Connecting(connecting, name),
                )
            }
            SessionPage::Failed => match imp.failed.borrow().as_ref() {
                Some(failed) => {
                    let view = ConnectFailureView::new(&failed.failure, &failed.source);
                    let page = ConnectFailedPage::new(
                        &view,
                        &edit_label(&failed.failure),
                        failed.failure.reenter,
                        app.as_ref(),
                    );
                    let toasts = page.toast_overlay();
                    (Some(page.clone().upcast()), Some(toasts), ShownPage::Failed(page))
                }
                None => (None, None, ShownPage::Other),
            },
            SessionPage::Shell => {
                let shell = self.shell();
                (
                    shell.clone().map(|shell| shell.upcast()),
                    shell.map(|shell| shell.toast_overlay()),
                    ShownPage::Other,
                )
            }
        };
        if page != SessionPage::Picker {
            imp.opened_for_file.set(false);
        }
        imp.page_toasts.replace(toasts);
        self.show_launch_notices();
        // A Cancel or Retry left as the default would take Enter on a
        // page that no longer shows it.
        self.set_default_widget(None::<&gtk::Widget>);
        self.set_content(child.as_ref());
        match shown {
            ShownPage::Connecting(page, name) => page.show(&name),
            ShownPage::Failed(page) => page.show(),
            ShownPage::Other => {}
        }
    }

    /// Each action is enabled where it means something, and the Safe
    /// Mode levels tick the session in front's.
    fn sync_actions(&self) {
        let page = self.page();
        if let Ok(failed) = self.imp().failed.try_borrow() {
            let failure = failed.as_ref().filter(|_| page == SessionPage::Failed).map(|failed| {
                let editable = ConnectFailureView::new(&failed.failure, &failed.source).can_edit;
                (&failed.failure, editable)
            });
            window_actions::sync(self.upcast_ref(), page, failure);
        }
        self.show_safe_mode();
    }

    /// A connect ended. One the window stopped, or started again after
    /// its file question, is not among its connects any more, and a
    /// connection it made is closed rather than adopted.
    fn on_attempt(&self, id: u64, result: Result<Connected, AttemptError>) {
        let position = self.imp().connects.borrow().iter().position(|pending| pending.id == id);
        let Some(position) = position else {
            if let Ok(connected) = result {
                self.discard_pending(connected.pending);
            }
            return;
        };
        if let Err(AttemptError::AskLocation(kind)) = &result {
            self.ask_about_location(id, kind);
            return;
        }
        let PendingConnect { claim, source, .. } = self.imp().connects.borrow_mut().remove(position);
        match result {
            Ok(connected) => {
                // The tree never shows a key both connecting and open.
                self.sync_tree();
                self.adopt(claim, source, connected);
            }
            Err(AttemptError::Failed(failure)) => self.on_connect_failed(claim, source, failure),
            // A location question was asked above, so this is a stop.
            Err(AttemptError::Cancelled | AttemptError::AskLocation(_)) => {
                let key = claim.key().clone();
                drop(claim);
                self.forget_session(&key);
            }
        }
        self.connects_changed();
    }

    /// With nothing else to show, the failed page says why and keeps the
    /// claim for its ways on. Beside a session or another connect, a
    /// toast says so and its Details say why. A session restored at
    /// launch that no longer opens is not tried again at the next one; a
    /// Retry that works records it again.
    fn on_connect_failed(&self, claim: SessionClaim, source: ConnectSource, failure: ConnectFailure) {
        tracing::warn!(error = %failure.message, "connect failed");
        let imp = self.imp();
        let key = claim.key().clone();
        self.forget_session(&key);
        let alone = imp.sessions.borrow().is_empty() && imp.connects.borrow().is_empty();
        if alone {
            let missing = match &source {
                ConnectSource::Saved(saved) => failure.missing_file.clone().map(|missing| (saved.id, missing)),
                _ => None,
            };
            self.show_failure(FailedConnect { claim, source, failure });
            if let Some((id, missing)) = missing {
                self.offer_locate(id, missing);
            }
            return;
        }
        drop(claim);
        let name = source_name(&source);
        if let Some(tree) = self.shell().and_then(|shell| shell.tree()) {
            tree.set_failure(&key, Some((&name, failure.message.as_str())));
        }
        imp.failures.borrow_mut().insert(key.clone(), (source, failure));
        // The toast goes to the page that shows from here on, which may
        // be another connect's progress.
        self.connects_changed();
        self.toast_failure(&key, &name);
    }

    /// Bring the session under `key` to the front: its last tab, or a new
    /// SQL editor when it has none.
    fn show_session(&self, key: &SessionKey) {
        if let (Some(shell), Some(workspace)) = (self.shell(), self.session_workspace(key)) {
            shell.show_session(&workspace);
        }
    }

    fn deliver_to(&self, key: &SessionKey, message: WorkspaceInput) {
        if let Some(input) = self.session_workspace(key).and_then(|workspace| workspace.sender()) {
            input.deliver(message);
        }
    }

    /// A tab belongs to its session, which only its own window holds: one
    /// dropped here goes back to the end of that window's tab bar.
    fn on_return_foreign_tab(&self, page: &adw::TabPage) {
        let (Some(shell), Some(app)) = (self.shell(), self.application()) else {
            return;
        };
        let view = shell.tab_view();
        if !(0..view.n_pages()).any(|position| &view.nth_page(position) == page) {
            return;
        }
        let owner = app
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<SessionWindow>().ok())
            .filter(|window| window != self)
            .filter_map(|window| window.shell())
            .find(|other| other.owner_of(page).is_some());
        let Some(owner) = owner else {
            tracing::debug!("a tab no other window's session owns was dropped here");
            return;
        };
        let target = owner.tab_view();
        view.transfer_page(page, &target, target.n_pages());
    }

    /// Start the session that connected and build its workspace in the
    /// window's shell, which the first session builds.
    fn adopt(&self, claim: SessionClaim, source: ConnectSource, connected: Connected) {
        let Connected {
            pending,
            saved,
            warnings,
            session_only,
        } = connected;
        let (Some(state), Some(_), Some(_)) = (self.state(), self.close_guards(), self.input()) else {
            self.discard_pending(pending);
            return;
        };
        let key = claim.key().clone();
        let credentials = state.context.session_credentials(saved.as_ref(), &session_only);
        let session = Session::start(pending, state.context.session_deps(credentials));
        self.remember_session(&key, saved.as_ref());
        if let ConnectSource::Intent(intent) = &source
            && let Err(error) = state
                .services
                .settings
                .set_connect_dialog_driver(&intent.request.metadata.driver_id)
        {
            tracing::warn!(%error, "could not remember the connect dialog driver");
        }
        self.join(claim, session, &warnings);
    }

    /// Build the workspace of a session that started, in the window's
    /// shell, which the first session builds. A connect and a sibling of
    /// another database both join this way.
    pub(super) fn join(&self, claim: SessionClaim, session: Arc<Session>, warnings: &[String]) {
        let (Some(state), Some(guards), Some(input)) = (self.state(), self.close_guards(), self.input()) else {
            return;
        };
        let key = claim.key().clone();
        claim.attach(&session);
        let shell = self.shell().unwrap_or_else(|| self.new_shell(state, &input));
        let workspace = Workspace::new(WorkspaceInit {
            key: key.clone(),
            session: session.clone(),
            services: state.services.clone(),
            context: state.context.clone(),
            window: self.clone().upcast(),
            close_guards: guards.clone(),
            shell: shell.clone(),
        });
        self.connect_workspace(&workspace, &input);
        self.imp().sessions.borrow_mut().push(OpenSession {
            claim,
            session,
            workspace: workspace.clone(),
        });
        self.render();
        shell.add_session(&workspace);
        workspace.start();
        self.sync_actions();
        for warning in warnings {
            self.show_toast(warning);
        }
        if let SessionKey::Saved(id) = key {
            self.touch_last_opened(id);
            self.open_waiting_databases(id);
        }
    }

    fn connect_workspace(&self, workspace: &Workspace, input: &InputSender<SessionWindowInput>) {
        let dirty = input.clone();
        workspace.connect_dirty_changed(move |_, _| dirty.deliver(SessionWindowInput::DirtyChanged));
        let saves = input.clone();
        workspace.connect_saves_in_flight_changed(move |_, _| saves.deliver(SessionWindowInput::SavesInFlightChanged));
        self.follow_workspace_tabs(workspace, input);
    }

    fn discard_pending(&self, pending: PendingSession) {
        if let Some(state) = self.state() {
            discard_pending(pending, &state.services.tasks, &*state.services.hold());
        }
    }

    /// Claim the key, then connect, so a second window asking for the
    /// same database brings the first forward instead of connecting.
    fn claim(&self, key: SessionKey) -> Option<SessionClaim> {
        let state = self.state()?;
        match state.context.sessions.claim(key.clone(), self.id()) {
            Ok(claim) => Some(claim),
            Err(ClaimError::AlreadyOpen { window_id }) => {
                // A window that stayed to say the owner could not be
                // shown is the user's picker from then on.
                let opened_for_file = self.imp().opened_for_file.replace(false);
                if self.present_owner(window_id, &key) && opened_for_file {
                    self.close();
                }
                None
            }
        }
    }

    /// False when the owner could not be brought forward, and this
    /// window says so instead.
    fn present_owner(&self, window_id: u32, key: &SessionKey) -> bool {
        let presented = self
            .state()
            .is_some_and(|state| state.host.present_session(window_id, key));
        if !presented {
            self.show_toast(&crate::i18n::gettext(
                "This connection is already open in another window.",
            ));
        }
        presented
    }

    /// The claim for a connect to `key`, unless the window shows that
    /// session already, which comes forward, or connects it already. A
    /// failed page about another key goes first; one about this key hands
    /// its claim over, since the dialog may be editing that connection.
    fn claim_for(&self, key: &SessionKey) -> Option<SessionClaim> {
        if self.holds_session(key) {
            self.show_session(key);
            return None;
        }
        if self.is_connecting(key) {
            return None;
        }
        match self.imp().failed.take() {
            Some(failed) if failed.claim.key() == key => Some(failed.claim),
            failed => {
                let left = failed.is_some();
                drop(failed);
                let claim = self.claim(key.clone());
                if claim.is_none() && left {
                    self.render();
                }
                claim
            }
        }
    }

    /// Every connect starts here, whatever asked for it: the picker, the
    /// tree, the connect dialog, a file, a restore, a Retry or MCP.
    fn connect(&self, source: ConnectSource, demand: CredentialDemand) {
        if let Some(claim) = self.claim_for(&source_key(&source)) {
            self.start_connect(claim, source, None, demand);
        }
    }

    /// Connect with the failed page's claim when there is one, else as
    /// any connect does.
    fn connect_with(&self, claim: Option<SessionClaim>, source: ConnectSource, demand: CredentialDemand) {
        match claim {
            Some(claim) => self.start_connect(claim, source, None, demand),
            None => self.connect(source, demand),
        }
    }

    fn on_open_saved(&self, saved: SavedConnection) {
        // A picker another window deleted the entry under still lists it.
        match self.saved_as_stored(&saved) {
            Some(saved) => self.connect(ConnectSource::Saved(Box::new(saved)), CredentialDemand::default()),
            None => self.show_toast(&crate::i18n::gettext("The connection was deleted.")),
        }
    }

    /// The file is resolved off the GTK thread: canonicalizing its path
    /// and matching it against the saved connections read the disk.
    fn on_open_file(&self, file: gio::File) {
        let Some(state) = self.state() else {
            return;
        };
        self.imp().opening_file.set(true);
        let path = file.path();
        let uri = file.uri().to_string();
        let resolving_uri = uri.clone();
        let connections = state.services.storage.connections().clone();
        let drivers = state.services.drivers.clone();
        let resolving = state
            .services
            .tasks
            .spawn_blocking_task(move || resolve_file_blocking(path, resolving_uri, &connections, &drivers));
        let input = self.input();
        glib::spawn_future_local(async move {
            let resolved = resolving.await.unwrap_or_else(|failure| ResolvedFile {
                uri,
                target: Err(FileResolveError::Interrupted(failure)),
            });
            if let Some(input) = input {
                input.deliver(SessionWindowInput::FileResolved(Box::new(resolved)));
            }
        });
    }

    /// A file restored under a key it no longer resolves to would be
    /// reopened under both, so that key is forgotten.
    fn on_file_resolved(&self, resolved: ResolvedFile) {
        self.imp().opening_file.set(false);
        let ResolvedFile { uri, target } = resolved;
        let arrived = SessionKey::File(uri.clone());
        self.end_restore(&arrived);
        match target {
            Ok(FileTarget::Saved(saved)) => {
                self.forget_unclaimed(&arrived);
                self.on_open_saved(*saved);
            }
            Ok(FileTarget::File(identity)) => {
                if identity.uri != uri {
                    self.forget_unclaimed(&arrived);
                }
                self.connect(ConnectSource::File(identity), CredentialDemand::default());
            }
            Err(error) => {
                tracing::warn!(%error, %uri, "could not open the file");
                self.forget_unclaimed(&arrived);
                let message = file_failure_message(&uri, &error);
                if !matches!(self.page(), SessionPage::Picker | SessionPage::Failed) {
                    self.show_toast(&message);
                    return;
                }
                let Some(claim) = self.claim_for(&arrived) else {
                    return;
                };
                self.show_failure(FailedConnect {
                    claim,
                    source: ConnectSource::File(FileIdentity::new(None, uri)),
                    failure: ConnectFailure::new(message),
                });
            }
        }
    }

    /// The dialog may be editing a connection the window shows or already
    /// connects, or one open in another window: its edits are kept for
    /// that connection's next connect.
    fn on_connect_from_dialog(&self, submission: ConnectSubmission) {
        let ConnectSubmission { request, pending_save } = submission;
        let key = SessionKey::Saved(pending_save.connection.id);
        match self.claim_for(&key) {
            Some(claim) => self.start_connect(
                claim,
                ConnectSource::Intent(Box::new(ConnectIntent {
                    key,
                    request,
                    pending_save: Some(pending_save),
                })),
                None,
                CredentialDemand::default(),
            ),
            None => self.persist_pending_save(pending_save),
        }
    }

    fn start_connect(
        &self,
        claim: SessionClaim,
        source: ConnectSource,
        answer: Option<bool>,
        demand: CredentialDemand,
    ) {
        if let Some(pending) = self.spawn_connect(claim, source, answer, demand) {
            self.imp().connects.borrow_mut().push(pending);
        }
        self.connects_changed();
    }

    /// Start connecting `source` under a new id, and give back what the
    /// window keeps of it. `answer` is how the user chose to open a
    /// database file on a filesystem whose locking the engines cannot
    /// trust, once asked. The key's last failure goes: this connect
    /// speaks for it now.
    fn spawn_connect(
        &self,
        claim: SessionClaim,
        source: ConnectSource,
        answer: Option<bool>,
        demand: CredentialDemand,
    ) -> Option<PendingConnect> {
        let state = self.state()?;
        let imp = self.imp();
        let id = imp.next_connect.get().wrapping_add(1);
        imp.next_connect.set(id);
        let key = claim.key();
        if imp.failures.borrow_mut().remove(key).is_some()
            && let Some(tree) = self.shell().and_then(|shell| shell.tree())
        {
            tree.set_failure(key, None);
        }
        let cancel = CancellationToken::new();
        let check = self.file_check(&source, answer);
        let work = connect_work(state, &source, check, demand, cancel.clone());
        self.deliver_attempt(work, id);
        Some(PendingConnect {
            id,
            claim,
            source,
            cancel,
            demand,
        })
    }

    /// The tree and the page follow the window's connects.
    fn connects_changed(&self) {
        self.sync_tree();
        self.render();
    }

    /// The tree shows a row connecting for each connect the window runs,
    /// and sets none itself.
    fn sync_tree(&self) {
        let Some(shell) = self.shell() else {
            return;
        };
        let connects: Vec<(SessionKey, String)> = self
            .imp()
            .connects
            .borrow()
            .iter()
            .map(|pending| (pending.claim.key().clone(), source_name(&pending.source)))
            .collect();
        if let Some(tree) = shell.tree() {
            tree.set_connects(&connects);
        }
    }

    /// Stop the connect for `key`. A result that still lands finds none
    /// waiting for it and is closed.
    fn stop_connecting(&self, key: &SessionKey) {
        let stopped = {
            let mut connects = self.imp().connects.borrow_mut();
            connects
                .iter()
                .position(|pending| pending.claim.key() == key)
                .map(|position| connects.remove(position))
        };
        if let Some(stopped) = stopped {
            self.drop_connect(stopped);
            self.connects_changed();
        }
    }

    /// Stop every connect the window runs.
    fn stop_connects(&self) {
        let stopped = match self.imp().connects.try_borrow_mut() {
            Ok(mut connects) => std::mem::take(&mut *connects),
            Err(_) => {
                tracing::warn!("the window's connects were stopped while they were read");
                return;
            }
        };
        for pending in stopped {
            self.drop_connect(pending);
        }
    }

    fn drop_connect(&self, pending: PendingConnect) {
        let PendingConnect { claim, cancel, .. } = pending;
        cancel.cancel();
        let key = claim.key().clone();
        drop(claim);
        self.forget_session(&key);
    }

    fn deliver_attempt(&self, work: BoxFuture<'static, Result<Connected, AttemptError>>, id: u64) {
        let Some(state) = self.state() else {
            return;
        };
        let input = self.input();
        let (tasks, hold) = (state.services.tasks.clone(), state.services.hold());
        crate::runtime::spawn_and_deliver(&state.services.tasks, work, move |outcome| {
            let result = outcome.unwrap_or_else(|failure| {
                Err(AttemptError::Failed(ConnectFailure::new(
                    crate::ui::error_text::task_failure_message(&failure),
                )))
            });
            let Some(input) = input else {
                return;
            };
            let attempt = SessionWindowCommand::Attempt { id, result };
            if let Err(unsent) = input.send(SessionWindowInput::Command(Box::new(attempt)))
                && let Some(pending) = unadopted(unsent.0)
            {
                discard_pending(pending, &tasks, &*hold);
            }
        });
    }

    /// The connecting page's Cancel stops every connect, since the window
    /// has nothing else; the failed page's Choose Connection leaves it.
    fn on_cancel_connect(&self) {
        match self.page() {
            SessionPage::Connecting(_) => self.stop_connects(),
            SessionPage::Failed => drop(self.imp().failed.take()),
            SessionPage::Picker | SessionPage::Shell => return,
        }
        self.connects_changed();
    }

    /// The key the failed page is about.
    fn failed_key(&self) -> Option<SessionKey> {
        self.imp()
            .failed
            .borrow()
            .as_ref()
            .map(|failed| failed.claim.key().clone())
    }

    /// Read the last failure for `key`: the failed page's, or one beside
    /// the window's sessions.
    pub(super) fn with_failure<R>(
        &self,
        key: &SessionKey,
        read: impl FnOnce(&ConnectSource, &ConnectFailure) -> R,
    ) -> Option<R> {
        let imp = self.imp();
        if let Some(failed) = imp.failed.borrow().as_ref().filter(|failed| failed.claim.key() == key) {
            return Some(read(&failed.source, &failed.failure));
        }
        imp.failures
            .borrow()
            .get(key)
            .map(|(source, failure)| read(source, failure))
    }

    /// Take the last failure for `key` to act on it, with the failed
    /// page's claim when it is the page's.
    pub(super) fn take_failure(
        &self,
        key: &SessionKey,
    ) -> Option<(Option<SessionClaim>, ConnectSource, ConnectFailure)> {
        let imp = self.imp();
        let page = imp.failed.borrow_mut().take_if(|failed| failed.claim.key() == key);
        if let Some(FailedConnect { claim, source, failure }) = page {
            return Some((Some(claim), source, failure));
        }
        let (source, failure) = imp.failures.borrow_mut().remove(key)?;
        if let Some(tree) = self.shell().and_then(|shell| shell.tree()) {
            tree.set_failure(key, None);
        }
        Some((None, source, failure))
    }

    /// Drop the last failure for `key` beside the window's sessions, and
    /// the tree's row for it when no saved connection names it.
    fn forget_failure(&self, key: &SessionKey) {
        if self.imp().failures.borrow_mut().remove(key).is_some()
            && let Some(tree) = self.shell().and_then(|shell| shell.tree())
        {
            tree.set_failure(key, None);
        }
    }

    /// Connect again from where the failed connect came from, reading
    /// the keyring again.
    fn on_retry_connect(&self, key: &SessionKey) {
        if let Some((claim, source, _)) = self.take_failure(key) {
            self.reconnect(claim, source, CredentialDemand::default());
        }
    }

    /// Connect `source` again as it is now: a file is resolved again,
    /// since it may have moved, and a saved connection read as saved now,
    /// since another window may have edited or deleted it.
    fn reconnect(&self, claim: Option<SessionClaim>, source: ConnectSource, demand: CredentialDemand) {
        match source {
            ConnectSource::File(identity) => {
                drop(claim);
                self.render();
                self.on_open_file(gio::File::for_uri(&identity.uri));
            }
            ConnectSource::Saved(saved) => match self.saved_as_stored(&saved) {
                Some(current) => self.connect_with(claim, ConnectSource::Saved(Box::new(current)), demand),
                None => {
                    drop(claim);
                    self.render();
                    self.show_toast(&crate::i18n::gettext("The connection was deleted."));
                }
            },
            source => self.connect_with(claim, source, demand),
        }
    }

    /// Edit Connection for a failed connect. A saved connection opens as
    /// an Edit of the entry as saved now, whose Save connects again; a
    /// new one reopens the connect dialog on what was typed.
    fn on_edit_connection(&self, key: &SessionKey) {
        let edit = self.with_failure(key, |source, failure| {
            (
                match source {
                    ConnectSource::Saved(saved) => Some((**saved).clone()),
                    _ => None,
                },
                connections::prefill_for(source),
                failure.remedy.map(crate::ui::connect_dialog::remedy_field),
            )
        });
        let Some((saved, prefill, focus)) = edit else {
            return;
        };
        match (saved, prefill) {
            (Some(saved), _) => match self.saved_as_stored(&saved) {
                Some(current) => self.present_connect_dialog(ConnectDialogMode::Edit(Box::new(current)), None, focus),
                None => self.show_toast(&crate::i18n::gettext("The connection was deleted.")),
            },
            (None, Some(prefill)) => {
                // What was typed becomes a new connection, under another
                // id, so this failure is left with nothing to try again.
                self.forget_failure(key);
                self.present_connect_dialog(ConnectDialogMode::Create, Some(prefill), focus);
            }
            (None, None) => {}
        }
    }

    fn on_disconnect_front(&self) {
        if let Some((key, _)) = self.front_session() {
            self.on_disconnect(key);
        }
    }

    fn on_session_teardown_approved(&self, key: &SessionKey) {
        if self.tear_down_session(key) {
            tracing::info!("disconnected");
        }
    }

    /// Close the session under `key` through its own prompts, then tear
    /// it down. The window's other sessions and connects go on.
    fn on_disconnect(&self, key: SessionKey) {
        // A connection's other databases go with it, each through its own
        // prompts (0030).
        if let SessionKey::Saved(id) = &key {
            for sibling in self.siblings_of(*id) {
                self.on_disconnect(sibling);
            }
        }
        let Some(workspace) = self.session_workspace(&key) else {
            return;
        };
        let (Some(handle), Some(guards)) = (workspace.prompt_handle(), self.close_guards()) else {
            return;
        };
        let approved = move || SessionWindowInput::SessionTeardownApproved(key.clone());
        guards.begin_teardown();
        if guards.may_tear_down(&handle) {
            self.send(approved());
            return;
        }
        let input = self.input();
        guards.ask_tear_down(self.upcast_ref(), &handle, move |decision| {
            if decision == CloseDecision::Approved
                && let Some(input) = input
            {
                input.deliver(approved());
            }
        });
    }

    /// Ctrl+W: the tab on screen closes through its session's prompts,
    /// and with no tab on screen the window closes through its own.
    fn on_close_current(&self) {
        let shown = self
            .shell()
            .is_some_and(|shell| shell.tab_view().selected_page().is_some());
        match self
            .workspace()
            .filter(|_| shown)
            .and_then(|workspace| workspace.sender())
        {
            Some(input) => input.deliver(WorkspaceInput::CloseActiveWorkspaceTab),
            None => self.close(),
        }
    }

    /// The window closes through one pass of the close prompts over every
    /// session: one Save Changes for all of them, and Cancel keeps them
    /// all.
    fn close_guards_for_window(&self) -> Rc<CloseGuards> {
        let guards = CloseGuards::new();
        let window = self.downgrade();
        guards.connect_window(
            self,
            move || {
                window
                    .upgrade()
                    .map(|window| window.workspace_handles())
                    .unwrap_or_default()
            },
            SessionWindow::on_close_approved,
        );
        guards
    }

    /// The close prompts approved the window's close, which goes ahead
    /// once this returns: what it holds is written and closed first.
    fn on_close_approved(&self) {
        if let Some(state) = self.state() {
            crate::ui::window_geometry::persist(self.upcast_ref(), &state.services.settings);
        }
        self.release_session();
    }

    /// Close every session the window holds, stop every connect it runs
    /// and let a failed connect's claim go.
    fn release_session(&self) {
        let imp = self.imp();
        self.abandon_restore();
        self.stop_connects();
        self.tear_down();
        match imp.failed.try_borrow_mut() {
            Ok(mut failed) => drop(failed.take()),
            Err(_) => tracing::warn!("the window closed while its failed connect was read"),
        }
        if let Ok(mut failures) = imp.failures.try_borrow_mut() {
            failures.clear();
        }
    }

    fn refresh_inhibitor(&self) {
        let imp = self.imp();
        let reason = InhibitReason::for_state(imp.dirty.get(), imp.saving.get());
        if let Some(inhibitor) = imp.inhibitor.borrow_mut().as_mut() {
            inhibitor.update(reason);
        }
    }

    #[cfg(test)]
    pub(crate) fn page_name(&self) -> &'static str {
        self.page().name()
    }
}

/// The connection a message carries that its window will never adopt
/// now. It is closed rather than dropped, so the server sees it end.
fn unadopted(message: SessionWindowInput) -> Option<PendingSession> {
    match message {
        SessionWindowInput::Command(command) => match *command {
            SessionWindowCommand::Attempt { result, .. } => result.ok().map(|connected| connected.pending),
        },
        _ => None,
    }
}

/// Throw away a connection nobody adopted, closing it under the close
/// deadline while the process stays alive for it.
fn discard_pending(pending: PendingSession, tasks: &tablepro_session::runtime::Tasks, hold: &dyn ProcessHold) {
    crate::runtime::spawn_held(tasks, hold, async move {
        let report = pending.discard().await;
        tracing::debug!(?report, "closed a connection that was not adopted");
    });
}

/// The connect a source makes, off the GTK thread, once `check` finds
/// its file safe to open. Reading the keyring, asking for what it lacks
/// and connecting all happen there; only the outcome comes back.
fn connect_work(
    state: &WindowState,
    source: &ConnectSource,
    check: FileCheck,
    demand: CredentialDemand,
    cancel: CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    let connecting = connect_source(state, source, check.read_only(), demand, cancel.clone());
    check.guard(&state.services.tasks, cancel, connecting)
}

/// `read_only` opens it read-only whatever the source says.
fn connect_source(
    state: &WindowState,
    source: &ConnectSource,
    read_only: bool,
    demand: CredentialDemand,
    cancel: CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    match source {
        ConnectSource::Saved(saved) => connect_saved(&state.context, saved, read_only, demand, cancel),
        ConnectSource::Intent(intent) => connect_intent(state, intent, read_only, cancel),
        ConnectSource::File(identity) => connect_file(&state.context, identity, read_only, cancel),
    }
}

fn connect_saved(
    context: &SessionContext,
    saved: &SavedConnection,
    read_only: bool,
    demand: CredentialDemand,
    cancel: CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    let connector = context.connector.clone();
    let interaction = context.attended();
    let saved = saved.clone();
    let mut opened = saved.clone();
    if read_only {
        opened.safe_mode = SafeModeLevel::ReadOnly;
    }
    let drivers = context.drivers.clone();
    let credentials = context.credentials_for(Some(&saved));
    let server_name_shown = crate::ui::connect_dialog::driver_shows_server_name(
        drivers
            .get(&saved.driver_id)
            .as_deref()
            .map(DatabaseDriver::capabilities),
        route(saved.ssh.is_some()),
    );
    async move {
        let connected = connect_flow::connect_saved(
            &opened,
            &drivers,
            &*credentials,
            &*connector,
            interaction,
            demand,
            cancel,
        )
        .await;
        match connected {
            Ok(login) => Ok(Connected {
                pending: login.pending,
                saved: Some(saved),
                warnings: login
                    .refused
                    .iter()
                    .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                    .collect(),
                session_only: login.session_only,
            }),
            Err(error) => Err(match attempt_error(&error, server_name_shown) {
                AttemptError::Failed(failure) => AttemptError::Failed(ConnectFailure {
                    reenter: secret_retry::refused_secret(&error, &saved),
                    ..failure
                }),
                cancelled => cancelled,
            }),
        }
    }
    .boxed()
}

/// A connection typed into the connect dialog, saved first when the
/// dialog asked for that.
fn connect_intent(
    state: &WindowState,
    intent: &ConnectIntent,
    read_only: bool,
    cancel: CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    let context = &state.context;
    let connector = context.connector.clone();
    let interaction = context.attended();
    let mut request = intent.request.clone();
    if read_only {
        request.open_read_only();
    }
    let server_name_shown = match &request.target {
        RequestTarget::Network { ssh, .. } => crate::ui::connect_dialog::driver_shows_server_name(
            Some(request.driver.capabilities()),
            route(ssh.is_some()),
        ),
        RequestTarget::File(_) => false,
    };
    let Some(pending_save) = intent.pending_save.clone() else {
        return async move {
            connect_flow::connect_request(&*connector, request, interaction, cancel)
                .await
                .map(unsaved)
                .map_err(|error| attempt_error(&error, server_name_shown))
        }
        .boxed();
    };
    let secrets = context.secrets.clone();
    let writes = StoreConnectionWrites::new(
        state.services.storage.connections().clone(),
        state.services.tasks.clone(),
    );
    async move {
        let saving = connect_flow::connect_then_save(
            &*connector,
            request,
            interaction,
            cancel,
            &*secrets,
            &writes,
            pending_save,
        )
        .await;
        match saving {
            Ok((pending, report)) => Ok(Connected {
                pending,
                // A keyring refusal must not be silent: the
                // connection opened, but the password will be
                // asked for next time.
                warnings: report
                    .secret_failures
                    .iter()
                    .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                    .collect(),
                session_only: report.secret_failures.iter().map(|(kind, _)| *kind).collect(),
                saved: Some(report.saved),
            }),
            Err(connect_flow::SubmitError::Connect(error)) => Err(attempt_error(&error, server_name_shown)),
            Err(connect_flow::SubmitError::Save(error)) => Err(AttemptError::Failed(ConnectFailure {
                heading: Some(crate::i18n::gettext("Could Not Save the Connection")),
                ..ConnectFailure::new(crate::ui::error_text::saved_connection_error_message(
                    &crate::services::saved_connection_error::SavedConnectionError::Storage(error),
                ))
            })),
        }
    }
    .boxed()
}

fn connect_file(
    context: &SessionContext,
    identity: &FileIdentity,
    read_only: bool,
    cancel: CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    let connector = context.connector.clone();
    let interaction = context.attended();
    let drivers = context.drivers.clone();
    let identity = identity.clone();
    let path = resolve_file_identity::file_path(&identity);
    let header_len = drivers.file_header_len();
    // Which engine opens the file is in its first bytes, read off the
    // GTK thread.
    let reading = context
        .tasks
        .spawn_blocking_task(move || resolve_file_identity::read_header_blocking(&path, header_len));
    async move {
        let header = cancel
            .run_until_cancelled(reading)
            .await
            .ok_or(AttemptError::Cancelled)?
            .map_err(|failure| DriverError::Protocol(format!("reading the file stopped: {failure}")))
            .and_then(|read| read)
            .map_err(|error| attempt_error(&ConnectError::Driver(error), false))?;
        let request = resolve_file_identity::file_request(&identity, &drivers, &header, read_only)
            .map_err(|error| attempt_error(&error, false))?;
        connect_flow::connect_request(&*connector, request, interaction, cancel)
            .await
            .map(unsaved)
            .map_err(|error| attempt_error(&error, false))
    }
    .boxed()
}

fn unsaved(pending: PendingSession) -> Connected {
    Connected {
        pending,
        saved: None,
        warnings: Vec::new(),
        session_only: Vec::new(),
    }
}

fn route(tunnelled: bool) -> TransportClass {
    if tunnelled {
        TransportClass::SshForward
    } else {
        TransportClass::DirectTcp
    }
}

/// `server_name_shown` says whether the connect dialog shows the server
/// name row for this connection, so a remedy never opens a hidden row.
fn attempt_error(error: &ConnectError, server_name_shown: bool) -> AttemptError {
    match error {
        ConnectError::Cancelled => AttemptError::Cancelled,
        error => AttemptError::Failed(ConnectFailure {
            message: crate::ui::error_text::connect_error_message(error),
            remedy: crate::ui::error_text::connect_remedy(error, server_name_shown),
            reenter: None,
            missing_file: match error {
                ConnectError::Driver(DriverError::FileNotFound { path }) => Some(path.clone()),
                _ => None,
            },
            heading: None,
        }),
    }
}

/// What the connecting page, the tree and a failure's toast call a
/// connect: the connection, or the file.
fn source_name(source: &ConnectSource) -> String {
    match source {
        ConnectSource::Saved(saved) => saved.name.clone(),
        ConnectSource::Intent(intent) => intent.request.metadata.name.clone(),
        ConnectSource::File(identity) => file_display_name(&identity.uri),
    }
}

fn file_display_name(uri: &str) -> String {
    let file = gio::File::for_uri(uri);
    file.basename()
        .map_or_else(|| uri.to_owned(), |name| name.to_string_lossy().into_owned())
}

/// The Edit button: named after the setting that fixes a TLS failure
/// when there is one.
fn edit_label(failure: &ConnectFailure) -> String {
    failure
        .remedy
        .map_or_else(|| crate::i18n::gettext("Edit Connection…"), |remedy| remedy.label())
}

/// A page that says what it shows once it is in the window.
enum ShownPage {
    Connecting(ConnectingPage, String),
    Failed(ConnectFailedPage),
    Other,
}

fn file_failure_message(uri: &str, error: &FileResolveError) -> String {
    let name = gio::File::for_uri(uri).parse_name().to_string();
    match error {
        FileResolveError::NotLocal => crate::i18n::gettext_f(
            "{file} is not on this computer. Copy it to a local folder to open it.",
            &[("file", &name)],
        ),
        FileResolveError::NotFound(_) => crate::i18n::gettext_f("{file} could not be found.", &[("file", &name)]),
        FileResolveError::Interrupted(failure) => crate::i18n::gettext_f(
            "{file} could not be opened. {reason}",
            &[
                ("file", &name),
                ("reason", &crate::ui::error_text::task_failure_message(failure)),
            ],
        ),
    }
}
