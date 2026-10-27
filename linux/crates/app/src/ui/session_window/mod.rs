//! A window of connection sessions. It opens on the picker, shows the
//! first connect while it runs and the failure when it fails, then the
//! shell with the session's workspace. Connections opened from then on
//! connect beside it and join the shell, each with its own workspace.
//! A disconnect tears one session's workspace down in order; the last
//! one returns the window to the picker. A workspace never moves to
//! another session.

mod application_notification_sink;
mod connect_failed_page;
mod connect_failure_view;
mod connect_flow;
mod connecting_page;
mod connections;
mod crash_notice;
mod file_location_dialog;
mod imp;
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
#[cfg(test)]
pub(crate) mod tests;
mod window_actions;
mod work_notifier;

use std::rc::Rc;

use futures::FutureExt;
use futures::future::BoxFuture;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::AdwApplicationWindowExt;

use tablepro_core::{DatabaseDriver, DriverError, SafeModeLevel, TransportClass};
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::registry::FileIdentity;
use tablepro_session::runtime::ProcessHold;
use tablepro_session::{
    ClaimError, ConnectAttempts, ConnectError, ConnectIntent, ConnectSource, MonitorSignal, PendingSession,
    RequestTarget, Session, SessionClaim, SessionKey,
};
use tablepro_storage::{CredentialDemand, SavedConnection};

pub(super) use self::connect_failed_page::ConnectFailedPage;
use self::connect_failure_view::ConnectFailureView;
pub(super) use self::connecting_page::ConnectingPage;
use self::file_location_dialog::FileCheck;
pub(super) use self::picker_page::PickerPage;
use self::resolve_file_identity::{FileResolveError, FileTarget, ResolvedFile, resolve_file_blocking};
use self::session_page::{BackgroundConnect, OpenSession, SessionPage};
pub(crate) use self::session_window_command::ConnectFailure;
use self::session_window_command::{AttemptError, Connected, SessionWindowCommand};
pub(crate) use self::session_window_input::SessionWindowInput;
use crate::application::{AppServices, WindowHost, WindowLaunch};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::session_context::SessionContext;
use crate::ui::connect_dialog::{ConnectDialogMode, ConnectSubmission};
use crate::ui::welcome_view::WelcomeView;
use crate::ui::workspace::{TreeRequest, Workspace, WorkspaceInit, WorkspaceInput, WorkspaceShell};
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
    /// added to the application, which gives it the id its session is
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

        self.show_page(SessionPage::Picker);
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
            WindowLaunch::Restore(keys) => {
                imp.restoring.replace(keys.clone());
                if let Some((first, rest)) = keys.split_first() {
                    imp.restore_waiting.replace(rest.to_vec());
                    input.deliver(SessionWindowInput::Restore(first.clone()));
                }
            }
            WindowLaunch::ConnectIntent(intent) => {
                let key = intent.key.clone();
                if let Some(claim) = self.claim(key) {
                    self.begin_connect(claim, ConnectSource::Intent(intent));
                }
            }
            WindowLaunch::ConnectFailed { source, failure } => self.show_failed_elsewhere(*source, *failure),
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
        self.page_is(|page| matches!(page, SessionPage::Picker))
            && !imp.opening_file.get()
            && !imp.dialog_opening.get()
            && imp.dialog.try_borrow().is_ok_and(|dialog| dialog.is_none())
    }

    /// Whether the window's claim is a session to reopen: it shows the
    /// session or is connecting it. A failed connect's claim is not.
    pub(crate) fn keeps_session(&self) -> bool {
        self.page_is(|page| matches!(page, SessionPage::Connecting { .. } | SessionPage::Workspace { .. }))
    }

    /// Whether the window holds logout back now, for its unsaved
    /// changes or for an export its workspace is writing.
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

    /// Stop the window's input and close what it still holds: the
    /// session it shows, or the connect it runs. Runs once, from the
    /// application as the window goes, or from dispose.
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

    fn page_is(&self, matches: impl FnOnce(&SessionPage) -> bool) -> bool {
        self.imp().page.try_borrow().is_ok_and(|page| matches(&page))
    }

    /// The workspace of the session in front, while the window shows
    /// its sessions.
    pub(crate) fn workspace(&self) -> Option<Workspace> {
        let page = self.imp().page.try_borrow().ok()?;
        page.front().map(|open| open.workspace.clone())
    }

    /// The workspace of every session the window holds.
    pub(crate) fn workspaces(&self) -> Vec<Workspace> {
        self.imp().page.try_borrow().map_or_else(
            |_| Vec::new(),
            |page| page.sessions().iter().map(|open| open.workspace.clone()).collect(),
        )
    }

    /// The workspace that holds tab `tab`.
    pub(crate) fn workspace_with_tab(&self, tab: uuid::Uuid) -> Option<Workspace> {
        self.workspaces()
            .into_iter()
            .find(|workspace| workspace.open_tabs().is_some_and(|tabs| tabs.contains(&tab)))
    }

    /// The window's shell, while it shows its sessions.
    pub(crate) fn shell(&self) -> Option<WorkspaceShell> {
        match &*self.imp().page.try_borrow().ok()? {
            SessionPage::Workspace { shell, .. } => Some(shell.clone()),
            _ => None,
        }
    }

    /// The shell for the window's first session. The window's actions and
    /// Safe Mode level follow whichever session comes to its front.
    fn new_shell(
        &self,
        saved: &std::rc::Rc<crate::services::saved_connection_list::SavedConnectionList>,
    ) -> WorkspaceShell {
        let shell = WorkspaceShell::new(self.upcast_ref(), saved.clone());
        let (input, list) = (self.input(), Some(saved.clone()));
        shell.set_tree_requests(move |request| {
            let (Some(input), Some(list)) = (input.as_ref(), list.as_ref()) else {
                return;
            };
            let message = match request {
                TreeRequest::Connect(SessionKey::Saved(id)) => match list.get(id) {
                    Some(saved) => SessionWindowInput::OpenSaved(Box::new(saved)),
                    None => {
                        input.deliver(SessionWindowInput::ShowToast(crate::i18n::gettext(
                            "The connection was deleted.",
                        )));
                        SessionWindowInput::ShowSession(SessionKey::Saved(id))
                    }
                },
                TreeRequest::Connect(key) | TreeRequest::Show(key) => SessionWindowInput::ShowSession(key),
                TreeRequest::Disconnect(key) => SessionWindowInput::DisconnectSession(key),
                TreeRequest::Edit(id) => SessionWindowInput::EditSavedConnection(id),
                TreeRequest::NewQuery(_) | TreeRequest::Refresh(_) | TreeRequest::Table(..) => return,
            };
            input.deliver(message);
        });
        let window = self.downgrade();
        shell.connect_front_changed(move |_| {
            if let Some(window) = window.upgrade() {
                window.sync_front();
                window.show_safe_mode();
            }
        });
        shell
    }

    /// Every session's, for the window's own close.
    fn workspace_handles(&self) -> Vec<WorkspaceHandle> {
        self.workspaces().iter().filter_map(Workspace::prompt_handle).collect()
    }

    /// A session said what it has to lose. One the window no longer
    /// holds has nothing left to lose, so its last word is dropped.
    fn on_dirty_changed(&self, key: &SessionKey, dirty: Option<bool>, saves: Option<usize>) {
        if self.imp().page.borrow().session(key).is_none() {
            return;
        }
        let others: Vec<Workspace> = self
            .workspaces()
            .into_iter()
            .filter(|workspace| workspace.key().as_ref() != Some(key))
            .collect();
        let imp = self.imp();
        if let Some(dirty) = dirty {
            imp.dirty.set(dirty || others.iter().any(Workspace::is_dirty));
        }
        if let Some(count) = saves {
            imp.saving.set(count > 0 || others.iter().any(Workspace::is_saving));
        }
        self.refresh_inhibitor();
    }

    /// Whether any session has something to lose, after one of them went.
    fn refresh_dirty(&self) {
        let workspaces = self.workspaces();
        self.imp().dirty.set(workspaces.iter().any(Workspace::is_dirty));
        self.imp().saving.set(workspaces.iter().any(Workspace::is_saving));
        self.refresh_inhibitor();
    }

    /// The window's actions, title and Safe Mode level follow the
    /// session that came to the front.
    fn sync_front(&self) {
        let Ok(page) = self.imp().page.try_borrow() else {
            return;
        };
        window_actions::sync(self.upcast_ref(), &page, false);
    }

    fn handle_input(&self, message: SessionWindowInput) {
        match message {
            SessionWindowInput::OpenSaved(saved) => self.on_open_saved(*saved),
            SessionWindowInput::OpenFile(file) => self.on_open_file(file),
            SessionWindowInput::FileResolved(resolved) => {
                self.on_file_resolved(*resolved);
                self.restore_on_picker();
            }
            SessionWindowInput::Restore(key) => self.on_restore(key),
            SessionWindowInput::RestoreSaved { id, saved } => {
                self.on_restore_saved(id, saved.map(|saved| *saved));
                self.restore_on_picker();
            }
            SessionWindowInput::RestoreUnread(key) => {
                self.end_restore(&key);
                self.restore_on_picker();
            }
            SessionWindowInput::OpenConnectDialog => {
                self.present_connect_dialog(ConnectDialogMode::Create, None, None);
            }
            SessionWindowInput::ConnectFromDialog(submission) => self.on_connect_from_dialog(*submission),
            SessionWindowInput::DialogClosed => drop(self.imp().dialog.take()),
            SessionWindowInput::CancelConnect => self.on_cancel_connect(),
            SessionWindowInput::RetryConnect => self.on_retry_connect(),
            SessionWindowInput::RetryWithNewSecret(kind) => self.on_retry_with_new_secret(kind),
            SessionWindowInput::EditConnection => self.on_edit_connection(),
            SessionWindowInput::EditSavedConnection(id) => self.on_edit_saved_connection(id),
            SessionWindowInput::ConnectionSaved(id) => self.on_connection_saved(id),
            SessionWindowInput::Disconnect => self.on_disconnect_front(),
            SessionWindowInput::DisconnectSession(key) => self.on_disconnect(key),
            SessionWindowInput::SessionTeardownApproved(key) => self.on_session_teardown_approved(&key),
            SessionWindowInput::ShowSession(key) => self.show_session(&key),
            SessionWindowInput::SetSafeMode(level) => self.on_set_safe_mode(level),
            SessionWindowInput::ReopenApproved(id) => self.on_reopen_approved(id),
            SessionWindowInput::CloseCurrent => self.on_close_current(),
            SessionWindowInput::Reconnect => {
                if let Some(open) = self.imp().page.borrow().front() {
                    open.session.signal(MonitorSignal::RetryNow);
                }
            }
            SessionWindowInput::ResetWorkspaceLayout => {
                if let Some(input) = self.workspace().and_then(|workspace| workspace.input()) {
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
            // Only the workspace on screen speaks for the window: one
            // torn down has nothing left to lose.
            SessionWindowInput::DirtyChanged(key, dirty) => self.on_dirty_changed(&key, Some(dirty), None),
            SessionWindowInput::SavesInFlightChanged(key, count) => self.on_dirty_changed(&key, None, Some(count)),
            SessionWindowInput::TitleChanged(title) => {
                if self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
                    self.set_title(Some(&title));
                }
            }
            SessionWindowInput::WorkCompleted(work) => self.on_work_completed(work),
            SessionWindowInput::TabsChanged => self.on_tabs_changed(),
            SessionWindowInput::FocusTab(tab) => self.on_focus_tab(tab),
            SessionWindowInput::Command(command) => match *command {
                SessionWindowCommand::Attempt { generation, result } => self.on_attempt(generation, result),
                SessionWindowCommand::BackgroundAttempt { key, serial, result } => {
                    self.on_background_attempt(&key, serial, result);
                }
            },
            SessionWindowInput::LocationChosen { generation, choice } => self.on_location_chosen(generation, choice),
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

    /// Move to `page`. The page left behind drops with what it held,
    /// which releases a claim. A workspace left behind is torn down
    /// first, so its session is closed rather than cut off.
    fn show_page(&self, page: SessionPage) {
        self.tear_down();
        let imp = self.imp();
        let app = self.application();
        let mut can_edit = false;
        let (child, toasts, shown): (Option<gtk::Widget>, Option<adw::ToastOverlay>, ShownPage) = match &page {
            SessionPage::Picker => {
                self.set_title(Some(&crate::i18n::gettext("TablePro")));
                let picker = imp.picker.get();
                (
                    picker.map(|picker| picker.clone().upcast()),
                    picker.map(PickerPage::toast_overlay),
                    ShownPage::Other,
                )
            }
            SessionPage::Connecting { source, .. } => {
                let connecting = ConnectingPage::new(app.as_ref());
                let toasts = connecting.toast_overlay();
                (
                    Some(connecting.clone().upcast()),
                    Some(toasts),
                    ShownPage::Connecting(connecting, source_name(source)),
                )
            }
            SessionPage::ConnectFailed { source, failure, .. } => {
                let view = ConnectFailureView::new(failure, source);
                can_edit = view.can_edit;
                let failed = ConnectFailedPage::new(&view, &edit_label(failure), failure.reenter, app.as_ref());
                let toasts = failed.toast_overlay();
                (Some(failed.clone().upcast()), Some(toasts), ShownPage::Failed(failed))
            }
            SessionPage::Workspace { shell, .. } => (
                Some(shell.clone().upcast()),
                Some(shell.toast_overlay()),
                ShownPage::Other,
            ),
        };
        window_actions::sync(self.upcast_ref(), &page, can_edit);
        if !matches!(page, SessionPage::Picker) {
            imp.opened_for_file.set(false);
        }
        let left = imp.page.replace(page);
        imp.page_toasts.replace(toasts);
        self.show_crash_notice();
        // A Cancel or Retry left as the default would take Enter on a
        // page that no longer shows it.
        self.set_default_widget(None::<&gtk::Widget>);
        self.set_content(child.as_ref());
        match shown {
            ShownPage::Connecting(page, name) => page.show(&name),
            ShownPage::Failed(page) => page.show(),
            ShownPage::Other => {}
        }
        drop(left);
    }

    /// A connect worked or failed. A late result, from an attempt the
    /// user cancelled or replaced, is closed rather than adopted.
    fn on_attempt(
        &self,
        generation: tablepro_session::connect::AttemptGeneration,
        result: Result<Connected, AttemptError>,
    ) {
        let imp = self.imp();
        let accepted = imp.attempts.accepts(generation);
        let current = accepted && self.page_is(|page| matches!(page, SessionPage::Connecting { .. }));
        if !current {
            if let Ok(connected) = result {
                self.discard_pending(connected.pending);
            }
            return;
        }
        let SessionPage::Connecting { claim, source } = imp.page.replace(SessionPage::Picker) else {
            return;
        };
        match result {
            Ok(connected) => self.adopt(claim, source, connected),
            Err(AttemptError::Cancelled) => {
                let key = claim.key().clone();
                drop(claim);
                self.show_page(SessionPage::Picker);
                self.forget_session(&key);
                self.continue_restore();
            }
            Err(AttemptError::AskLocation(kind)) => {
                imp.page.replace(SessionPage::Connecting { claim, source });
                self.ask_about_location(generation, &kind);
            }
            // A session restored at launch that no longer opens is not
            // tried again at the next one; a Retry that works records it.
            Err(AttemptError::Failed(failure)) => {
                tracing::warn!(error = %failure.message, "connect failed");
                let key = claim.key().clone();
                let missing = match &source {
                    ConnectSource::Saved(saved) => failure.missing_file.clone().map(|missing| (saved.id, missing)),
                    _ => None,
                };
                self.show_page(SessionPage::ConnectFailed { claim, source, failure });
                self.forget_session(&key);
                if let Some((id, missing)) = missing {
                    self.offer_locate(id, missing);
                }
                self.continue_restore();
            }
        }
    }

    /// A connect that ran beside the window's sessions ended. Its session
    /// joins them. A failure the tree's row can try again says why in a
    /// toast; one that needs the failed page's remedies, or a connection
    /// the dialog has not saved yet, gets that page in a window of its
    /// own, without connecting again.
    fn on_background_attempt(&self, key: &SessionKey, serial: u64, result: Result<Connected, AttemptError>) {
        let running = {
            let mut background = self.imp().background.borrow_mut();
            background
                .iter()
                .position(|running| running.claim.key() == key && running.serial == serial)
                .map(|position| background.remove(position))
        };
        // The window stopped this connect, or another took its place.
        let Some(BackgroundConnect { claim, source, .. }) = running else {
            if let Ok(connected) = result {
                self.discard_pending(connected.pending);
            }
            return;
        };
        if let Some(shell) = self.shell() {
            shell.set_connecting(key, false);
        }
        match result {
            Ok(connected) => self.adopt(claim, source, connected),
            Err(AttemptError::Cancelled) => {
                drop(claim);
                self.forget_session(key);
            }
            // Asking about the file's location belongs to a window of its
            // own, as the first connect of a window asks it.
            Err(AttemptError::AskLocation(_)) => {
                drop(claim);
                self.forget_session(key);
                self.open_in_new_window(source);
            }
            Err(AttemptError::Failed(failure)) => {
                tracing::warn!(error = %failure.message, "connect failed");
                drop(claim);
                self.forget_session(key);
                let needs_page = matches!(source, ConnectSource::Intent(_))
                    || failure.remedy.is_some()
                    || failure.reenter.is_some()
                    || failure.missing_file.is_some();
                if needs_page && let Some(state) = self.state() {
                    state.host.open_window(WindowLaunch::ConnectFailed {
                        source: Box::new(source),
                        failure: Box::new(failure),
                    });
                    return;
                }
                self.show_toast(&crate::i18n::gettext_f(
                    "Could not connect to {name}. {reason}",
                    &[("name", &source_name(&source)), ("reason", &failure.message)],
                ));
            }
        }
    }

    fn open_in_new_window(&self, source: ConnectSource) {
        let Some(state) = self.state() else {
            return;
        };
        match source {
            ConnectSource::Saved(saved) => state.host.open_window(WindowLaunch::Connect(saved)),
            ConnectSource::File(identity) => {
                state
                    .host
                    .open_window(WindowLaunch::OpenFile(gio::File::for_uri(&identity.uri)));
            }
            // The dialog's connection asks in a window of its own too,
            // which keeps what it would save.
            ConnectSource::Intent(intent) => state.host.open_window(WindowLaunch::ConnectIntent(intent)),
        }
    }

    /// Bring the session under `key` to the front, with one of its tabs.
    fn show_session(&self, key: &SessionKey) {
        let Some(shell) = self.shell() else {
            return;
        };
        let workspace = self.imp().page.borrow().session(key).map(|open| open.workspace.clone());
        let Some(workspace) = workspace else {
            // A row asked for a session that did not open stops saying it
            // connects.
            shell.set_connecting(key, self.connecting_beside(key));
            return;
        };
        // The front follows the tab on screen. A session with no tab
        // stays behind until the user opens one, from its row's New Query
        // or a table; a tab nobody asked for would be saved with it.
        if let Some(page) = workspace.some_page() {
            shell.tab_view().set_selected_page(&page);
        }
    }

    /// Start the session that connected and build its workspace, in the
    /// window's shell, which it builds for the first session.
    fn adopt(&self, claim: SessionClaim, source: ConnectSource, connected: Connected) {
        let Connected {
            pending,
            saved,
            warnings,
            session_only,
        } = connected;
        let (Some(state), Some(guards)) = (self.state(), self.close_guards()) else {
            self.discard_pending(pending);
            return;
        };
        let key = claim.key().clone();
        let credentials = state.context.session_credentials(saved.as_ref(), &session_only);
        let session = Session::start(pending, state.context.session_deps(credentials));
        claim.attach(&session);
        self.remember_session(&key, saved.as_ref());
        if let ConnectSource::Intent(intent) = &source
            && let Err(error) = state
                .services
                .settings
                .set_connect_dialog_driver(&intent.request.metadata.driver_id)
        {
            tracing::warn!(%error, "could not remember the connect dialog driver");
        }
        let held = self.shell();
        let shell = held
            .clone()
            .unwrap_or_else(|| self.new_shell(&state.services.saved_connections));
        let workspace = Workspace::new(WorkspaceInit {
            key: key.clone(),
            session: session.clone(),
            services: state.services.clone(),
            context: state.context.clone(),
            window: self.clone().upcast(),
            close_guards: guards.clone(),
            shell: shell.clone(),
        });
        self.connect_workspace(&workspace);
        let open = OpenSession {
            claim,
            session,
            workspace: workspace.clone(),
        };
        if held.is_some() {
            if let SessionPage::Workspace { sessions, .. } = &mut *self.imp().page.borrow_mut() {
                sessions.push(open);
            }
        } else {
            self.show_page(SessionPage::Workspace {
                shell: shell.clone(),
                sessions: vec![open],
            });
        }
        let from_dialog = matches!(source, ConnectSource::Intent(_));
        shell.add_session(&workspace);
        workspace.start();
        self.sync_front();
        // A connect beside the sessions can land while the user has a
        // dialog open for something else, which stays the window's.
        if held.is_none() || from_dialog {
            drop(self.imp().dialog.take());
        }
        for warning in warnings {
            self.show_toast(&warning);
        }
        if let SessionKey::Saved(id) = key {
            self.touch_last_opened(id);
        }
        self.continue_restore();
    }

    /// Show a connect another window could not finish, on the failed
    /// page this window would have shown for it.
    fn show_failed_elsewhere(&self, source: ConnectSource, failure: ConnectFailure) {
        let key = match &source {
            ConnectSource::Saved(saved) => SessionKey::Saved(saved.id),
            ConnectSource::Intent(intent) => intent.key.clone(),
            ConnectSource::File(identity) => SessionKey::File(identity.uri.clone()),
        };
        let Some(claim) = self.claim(key) else {
            return;
        };
        let missing = match &source {
            ConnectSource::Saved(saved) => failure.missing_file.clone().map(|missing| (saved.id, missing)),
            _ => None,
        };
        self.show_page(SessionPage::ConnectFailed { claim, source, failure });
        if let Some((id, missing)) = missing {
            self.offer_locate(id, missing);
        }
    }

    fn connect_workspace(&self, workspace: &Workspace) {
        let Some(input) = self.input() else {
            return;
        };
        let Some(key) = workspace.key() else {
            return;
        };
        let (dirty, dirty_key) = (input.clone(), key.clone());
        workspace.connect_dirty_changed(move |_, value| {
            dirty.deliver(SessionWindowInput::DirtyChanged(dirty_key.clone(), value));
        });
        let saves = input.clone();
        workspace.connect_saves_in_flight_changed(move |_, count| {
            saves.deliver(SessionWindowInput::SavesInFlightChanged(key.clone(), count));
        });
        self.follow_workspace_tabs(workspace, &input);
        workspace.connect_title_changed(move |_, title| input.deliver(SessionWindowInput::TitleChanged(title)));
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

    fn on_open_saved(&self, saved: SavedConnection) {
        let Some(state) = self.state() else {
            return;
        };
        // A picker another window deleted the entry under still lists it.
        let Some(saved) = self.saved_as_stored(&saved) else {
            self.show_toast(&crate::i18n::gettext("The connection was deleted."));
            if let Some(shell) = self.shell() {
                shell.set_connecting(&SessionKey::Saved(saved.id), false);
            }
            return;
        };
        let key = SessionKey::Saved(saved.id);
        if self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
            if self.shown_beside(&key) {
                // A row keeps saying it connects while it does.
            } else if let Some(claim) = self.claim(key.clone()) {
                self.begin_background_connect(claim, ConnectSource::Saved(Box::new(saved)));
                return;
            }
            if let Some(shell) = self.shell() {
                shell.set_connecting(&key, self.connecting_beside(&key));
            }
            return;
        }
        if !self.page_is(|page| matches!(page, SessionPage::Picker)) {
            // This window is connecting; another one opens this.
            if let Some(owner) = state.context.sessions.window_for(&key)
                && state.host.present_session(owner, &key)
            {
                return;
            }
            state.host.open_window(WindowLaunch::Connect(Box::new(saved)));
            return;
        }
        if let Some(claim) = self.claim(SessionKey::Saved(saved.id)) {
            self.begin_connect(claim, ConnectSource::Saved(Box::new(saved)));
        }
    }

    /// The file is resolved off the GTK thread: canonicalizing its path
    /// and matching it against the saved connections read the disk.
    fn on_open_file(&self, file: gio::File) {
        let Some(state) = self.state() else {
            return;
        };
        if !self.page_is(|page| matches!(page, SessionPage::Picker | SessionPage::Workspace { .. })) {
            state.host.open_window(WindowLaunch::OpenFile(file));
            return;
        }
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

    fn on_file_resolved(&self, resolved: ResolvedFile) {
        self.imp().opening_file.set(false);
        let ResolvedFile { uri, target } = resolved;
        self.end_restore(&SessionKey::File(uri.clone()));
        let beside = self.page_is(|page| matches!(page, SessionPage::Workspace { .. }));
        if !beside && !self.page_is(|page| matches!(page, SessionPage::Picker)) {
            if let Some(state) = self.state() {
                state.host.open_window(WindowLaunch::OpenFile(gio::File::for_uri(&uri)));
            }
            return;
        }
        // A file restored under a key it no longer resolves to would be
        // reopened under both.
        let arrived = SessionKey::File(uri.clone());
        match target {
            Ok(FileTarget::Saved(saved)) => {
                self.forget_unclaimed(&arrived);
                self.on_open_saved(*saved);
            }
            Ok(FileTarget::File(identity)) => {
                if identity.uri != uri {
                    self.forget_unclaimed(&arrived);
                }
                let key = SessionKey::File(identity.uri.clone());
                if beside && self.shown_beside(&key) {
                    return;
                }
                if let Some(claim) = self.claim(key) {
                    if beside {
                        self.begin_background_connect(claim, ConnectSource::File(identity));
                    } else {
                        self.begin_connect(claim, ConnectSource::File(identity));
                    }
                }
            }
            Err(error) if beside => {
                tracing::warn!(%error, %uri, "could not open the file");
                self.forget_unclaimed(&arrived);
                self.show_toast(&file_failure_message(&uri, &error));
            }
            Err(error) => {
                tracing::warn!(%error, %uri, "could not open the file");
                self.forget_unclaimed(&arrived);
                let Some(claim) = self.claim(SessionKey::File(uri.clone())) else {
                    return;
                };
                let failure = ConnectFailure::new(file_failure_message(&uri, &error));
                self.show_page(SessionPage::ConnectFailed {
                    claim,
                    source: ConnectSource::File(FileIdentity::new(None, uri)),
                    failure,
                });
                self.continue_restore();
            }
        }
    }

    fn on_connect_from_dialog(&self, submission: ConnectSubmission) {
        let ConnectSubmission { request, pending_save } = submission;
        let beside = match &*self.imp().page.borrow() {
            SessionPage::Picker | SessionPage::ConnectFailed { .. } => false,
            SessionPage::Workspace { .. } => true,
            SessionPage::Connecting { .. } => {
                tracing::warn!("a connect from the dialog reached a window that is connecting");
                return;
            }
        };
        if beside {
            let key = SessionKey::Saved(pending_save.connection.id);
            // The edits are kept for the next connect.
            if self.shown_beside(&key) {
                self.persist_pending_save(pending_save);
                return;
            }
            match self.claim(key.clone()) {
                Some(claim) => self.begin_background_connect(
                    claim,
                    ConnectSource::Intent(Box::new(ConnectIntent {
                        key,
                        request,
                        pending_save: Some(pending_save),
                    })),
                ),
                None => self.persist_pending_save(pending_save),
            }
            return;
        }
        // A failed connect's claim goes first: the dialog may be editing
        // that same connection.
        self.show_page(SessionPage::Picker);
        let key = SessionKey::Saved(pending_save.connection.id);
        let Some(state) = self.state() else {
            return;
        };
        match state.context.sessions.claim(key.clone(), self.id()) {
            Ok(claim) => self.begin_connect(
                claim,
                ConnectSource::Intent(Box::new(ConnectIntent {
                    key,
                    request,
                    pending_save: Some(pending_save),
                })),
            ),
            Err(ClaimError::AlreadyOpen { window_id }) => {
                // The edits are kept for the next connect; the session
                // open in the other window goes on as it was.
                self.persist_pending_save(pending_save);
                self.present_owner(window_id, &key);
            }
        }
    }

    fn begin_connect(&self, claim: SessionClaim, source: ConnectSource) {
        self.start_connect(claim, source, None, CredentialDemand::default());
    }

    fn begin_connect_with(&self, claim: SessionClaim, source: ConnectSource, demand: CredentialDemand) {
        self.start_connect(claim, source, None, demand);
    }

    /// `answer` is how the user chose to open a database file on a
    /// filesystem whose locking the engines cannot trust, once asked.
    fn start_connect(
        &self,
        claim: SessionClaim,
        source: ConnectSource,
        answer: Option<bool>,
        demand: CredentialDemand,
    ) {
        let Some(state) = self.state() else {
            return;
        };
        let check = self.file_check(&source, answer);
        let ticket = self.imp().attempts.begin();
        let generation = ticket.generation();
        let cancel = ticket.cancel().clone();
        let work = connect_work(state, &source, check, demand, cancel);
        self.show_page(SessionPage::Connecting { claim, source });
        self.deliver_attempt(work, move |result| SessionWindowCommand::Attempt { generation, result });
    }

    /// Connect `source` while the window keeps showing its sessions,
    /// beside any other connect running there.
    fn begin_background_connect(&self, claim: SessionClaim, source: ConnectSource) {
        let Some(state) = self.state() else {
            return;
        };
        let imp = self.imp();
        let key = claim.key().clone();
        let check = self.file_check(&source, None);
        let attempts = ConnectAttempts::new();
        let ticket = attempts.begin();
        let cancel = ticket.cancel().clone();
        let work = connect_work(state, &source, check, CredentialDemand::default(), cancel);
        let serial = imp.background_serial.get().wrapping_add(1);
        imp.background_serial.set(serial);
        if let Some(shell) = self.shell() {
            shell.set_connecting(&key, true);
        }
        self.show_toast(&crate::i18n::gettext_f(
            "Connecting to {name}…",
            &[("name", &source_name(&source))],
        ));
        imp.background.borrow_mut().push(BackgroundConnect {
            claim,
            source,
            serial,
            attempts,
        });
        self.deliver_attempt(work, move |result| SessionWindowCommand::BackgroundAttempt {
            key,
            serial,
            result,
        });
    }

    /// A key the window holds comes to the front, and one connecting
    /// beside its sessions goes on: true when there is nothing to start.
    fn shown_beside(&self, key: &SessionKey) -> bool {
        if self.imp().page.borrow().session(key).is_some() {
            self.show_session(key);
            return true;
        }
        self.connecting_beside(key)
    }

    /// Whether a connect for `key` runs beside the window's sessions.
    fn connecting_beside(&self, key: &SessionKey) -> bool {
        self.imp()
            .background
            .borrow()
            .iter()
            .any(|running| running.claim.key() == key)
    }

    /// Stop every connect running beside the sessions. A result that
    /// still lands finds none waiting for it and is closed.
    fn stop_background_connects(&self) -> Vec<SessionKey> {
        let stopped = self.imp().background.take();
        let keys = stopped.iter().map(|running| running.claim.key().clone()).collect();
        for running in stopped {
            self.stop_background_connect(running);
        }
        keys
    }

    /// The user stopped a connect running beside the sessions.
    fn stop_connecting_beside(&self, key: &SessionKey) {
        let stopped = {
            let mut background = self.imp().background.borrow_mut();
            background
                .iter()
                .position(|running| running.claim.key() == key)
                .map(|position| background.remove(position))
        };
        if let Some(stopped) = stopped {
            self.stop_background_connect(stopped);
        }
    }

    fn stop_background_connect(&self, running: BackgroundConnect) {
        let BackgroundConnect { claim, attempts, .. } = running;
        attempts.cancel();
        let key = claim.key().clone();
        drop(claim);
        if let Some(shell) = self.shell() {
            shell.set_connecting(&key, false);
        }
        self.forget_session(&key);
    }

    /// The window's last session went. The newest connect still running
    /// beside it becomes the window's own on the connecting page, which
    /// cancels and fails as a first connect does; it starts over there,
    /// since its result was bound for a page that is gone. The others
    /// stop, and with none the picker comes back.
    fn after_last_session(&self) {
        let mut running = self.imp().background.take();
        let resumed = running.pop();
        for other in running {
            self.stop_background_connect(other);
        }
        match resumed {
            Some(BackgroundConnect {
                claim,
                source,
                attempts,
                ..
            }) => {
                attempts.cancel();
                self.begin_connect(claim, source);
            }
            None => {
                self.show_page(SessionPage::Picker);
                self.continue_restore();
            }
        }
    }

    fn deliver_attempt(
        &self,
        work: BoxFuture<'static, Result<Connected, AttemptError>>,
        command: impl FnOnce(Result<Connected, AttemptError>) -> SessionWindowCommand + Send + 'static,
    ) {
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
            let attempt = command(result);
            let Some(input) = input else {
                return;
            };
            if let Err(unsent) = input.send(SessionWindowInput::Command(Box::new(attempt)))
                && let Some(pending) = unadopted(unsent.0)
            {
                discard_pending(pending, &tasks, &*hold);
            }
        });
    }

    /// Stop the connect in progress, or leave a failed one, for the
    /// picker.
    fn on_cancel_connect(&self) {
        if self.page_is(|page| matches!(page, SessionPage::Connecting { .. })) {
            stop_connecting(&self.imp().attempts);
        }
        if self.page_is(|page| matches!(page, SessionPage::Connecting { .. } | SessionPage::ConnectFailed { .. })) {
            let key = self.imp().page.borrow().key().cloned();
            self.show_page(SessionPage::Picker);
            if let Some(key) = key {
                self.forget_session(&key);
            }
            self.continue_restore();
        }
    }

    fn on_retry_connect(&self) {
        let imp = self.imp();
        if !self.page_is(|page| matches!(page, SessionPage::ConnectFailed { .. })) {
            return;
        }
        let SessionPage::ConnectFailed { claim, source, .. } = imp.page.replace(SessionPage::Picker) else {
            return;
        };
        match source {
            // The file is resolved again, since it may have moved.
            ConnectSource::File(identity) => {
                drop(claim);
                self.show_page(SessionPage::Picker);
                self.on_open_file(gio::File::for_uri(&identity.uri));
            }
            ConnectSource::Saved(saved) => self.reconnect_saved(claim, *saved, CredentialDemand::default()),
            source => self.begin_connect(claim, source),
        }
    }

    /// Connect a failed saved connection again, as it is saved now: the
    /// entry may have been edited or deleted in another window since.
    fn reconnect_saved(&self, claim: SessionClaim, saved: SavedConnection, demand: CredentialDemand) {
        match self.saved_as_stored(&saved) {
            Some(current) => self.begin_connect_with(claim, ConnectSource::Saved(Box::new(current)), demand),
            None => {
                drop(claim);
                self.show_page(SessionPage::Picker);
                self.show_toast(&crate::i18n::gettext("The connection was deleted."));
            }
        }
    }

    /// The failed page's Edit Connection. A saved connection opens as an
    /// Edit of the entry as saved now, whose Save connects again; a new
    /// one reopens the connect dialog on what was typed.
    fn on_edit_connection(&self) {
        let (saved, prefill, focus) = match &*self.imp().page.borrow() {
            SessionPage::ConnectFailed { source, failure, .. } => (
                match source {
                    ConnectSource::Saved(saved) => Some((**saved).clone()),
                    _ => None,
                },
                connections::prefill_for(source),
                failure.remedy.map(crate::ui::connect_dialog::remedy_field),
            ),
            _ => return,
        };
        match (saved, prefill) {
            (Some(saved), _) => match self.saved_as_stored(&saved) {
                Some(current) => self.present_connect_dialog(ConnectDialogMode::Edit(Box::new(current)), None, focus),
                None => self.show_toast(&crate::i18n::gettext("The connection was deleted.")),
            },
            (None, Some(prefill)) => self.present_connect_dialog(ConnectDialogMode::Create, Some(prefill), focus),
            (None, None) => {}
        }
    }

    fn on_disconnect_front(&self) {
        let key = self.imp().page.borrow().front().map(|open| open.claim.key().clone());
        if let Some(key) = key {
            self.on_disconnect(key);
        }
    }

    /// The window keeps its other sessions; the picker comes back once
    /// none is left.
    fn on_session_teardown_approved(&self, key: &SessionKey) {
        if !self.tear_down_session(key) {
            return;
        }
        if !self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
            self.after_last_session();
        }
        tracing::info!("disconnected");
    }

    /// Close the session under `key` through its prompts. With no other
    /// session, the whole page goes and the picker comes back.
    fn on_disconnect(&self, key: SessionKey) {
        let workspace = self
            .imp()
            .page
            .borrow()
            .session(&key)
            .map(|open| open.workspace.clone());
        let Some(workspace) = workspace else {
            self.stop_connecting_beside(&key);
            return;
        };
        let (Some(handle), Some(guards)) = (workspace.prompt_handle(), self.close_guards()) else {
            return;
        };
        // Whether it is the last is decided once approved: a session can
        // join while the prompt is open.
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

    /// Ctrl+W: the workspace closes its current tab, and with no
    /// workspace the window closes, through its close prompts.
    fn on_close_current(&self) {
        match self.workspace().and_then(|workspace| workspace.input()) {
            Some(input) => input.deliver(WorkspaceInput::CloseActiveWorkspaceTab),
            None => self.close(),
        }
    }

    /// The window closes through every session's prompts in turn.
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
        let window = self.downgrade();
        guards.on_part_approved(move |handle| {
            if let Some(window) = window.upgrade() {
                window.close_approved_part(handle);
            }
        });
        guards
    }

    /// One session's prompt approved the window's close and the next is
    /// asked: the session goes now, with what its prompt saved or
    /// discarded, whatever the next one answers.
    fn close_approved_part(&self, handle: &crate::workspace::WorkspaceHandle) {
        let key = self
            .imp()
            .page
            .borrow()
            .sessions()
            .iter()
            .find(|open| open.workspace.handle().is_some_and(|held| held.same(handle)))
            .map(|open| open.claim.key().clone());
        if let Some(key) = key {
            self.send(SessionWindowInput::SessionTeardownApproved(key));
        }
    }

    /// The close prompts approved the window's close, which goes ahead
    /// once this returns: what it holds is written and closed first.
    fn on_close_approved(&self) {
        if let Some(state) = self.state() {
            crate::ui::window_geometry::persist(self.upcast_ref(), &state.services.settings);
        }
        self.release_session();
    }

    /// Close the session the window shows, or stop the connect it runs.
    fn release_session(&self) {
        self.abandon_restore();
        drop(self.stop_background_connects());
        if self.tear_down() {
            return;
        }
        if self.page_is(|page| matches!(page, SessionPage::Connecting { .. })) {
            stop_connecting(&self.imp().attempts);
        }
        let left = match self.imp().page.try_borrow_mut() {
            Ok(mut page) => std::mem::take(&mut *page),
            Err(_) => {
                tracing::warn!("the window closed while its page was in use");
                return;
            }
        };
        let key = left.key().cloned();
        drop(left);
        if let Some(key) = key {
            self.forget_session(&key);
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
        self.imp().page.borrow().name()
    }
}

/// The connection a message carries that its window will never adopt
/// now. It is closed rather than dropped, so the server sees it end.
fn unadopted(message: SessionWindowInput) -> Option<PendingSession> {
    match message {
        SessionWindowInput::Command(command) => match *command {
            SessionWindowCommand::Attempt { result, .. } | SessionWindowCommand::BackgroundAttempt { result, .. } => {
                result.ok().map(|connected| connected.pending)
            }
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

/// Supersede the connect in flight, not only cancel it: a driver
/// blocked in a socket call can still connect afterwards, and that late
/// session must not be adopted.
fn stop_connecting(attempts: &tablepro_session::ConnectAttempts) {
    drop(attempts.begin());
    attempts.cancel();
}

/// The connect a source makes, off the GTK thread, once `check` finds
/// its file safe to open. Reading the keyring, asking for what it lacks
/// and connecting all happen there; only the outcome comes back.
fn connect_work(
    state: &WindowState,
    source: &ConnectSource,
    check: FileCheck,
    demand: CredentialDemand,
    cancel: tokio_util::sync::CancellationToken,
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
    cancel: tokio_util::sync::CancellationToken,
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
    cancel: tokio_util::sync::CancellationToken,
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
    cancel: tokio_util::sync::CancellationToken,
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
    cancel: tokio_util::sync::CancellationToken,
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

/// What the connecting page names: the connection, or the file.
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

/// The failed page's Edit button: named after the setting that fixes a
/// TLS failure when there is one.
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
