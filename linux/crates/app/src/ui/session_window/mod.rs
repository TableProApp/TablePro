//! One window per connection session. It opens on the picker, shows
//! the connect while it runs and the failure when it fails, then the
//! session's workspace. A disconnect tears the workspace down in order
//! and returns to the picker; it never moves to another session.

mod connect_failed_page;
mod connect_flow;
mod connecting_page;
mod connections;
mod imp;
mod picker_page;
mod resolve_file_identity;
mod secret_retry;
mod session_page;
mod session_teardown;
mod session_window_command;
mod session_window_input;
#[cfg(test)]
pub(crate) mod tests;
mod window_actions;

use std::rc::Rc;

use futures::FutureExt;
use futures::future::BoxFuture;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use relm4::prelude::*;

use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::registry::FileIdentity;
use tablepro_session::runtime::ProcessHold;
use tablepro_session::{
    ClaimError, ConnectError, ConnectIntent, ConnectSource, MonitorSignal, PendingSession, Session, SessionClaim,
    SessionKey,
};
use tablepro_storage::{CredentialDemand, SavedConnection};

use self::connect_failed_page::ConnectFailedPage;
use self::connecting_page::ConnectingPage;
use self::picker_page::PickerPage;
use self::resolve_file_identity::{FileResolveError, FileTarget, ResolvedFile, resolve_file_blocking};
use self::session_page::SessionPage;
use self::session_window_command::{AttemptError, ConnectFailure, Connected, SessionWindowCommand};
pub(crate) use self::session_window_input::SessionWindowInput;
pub(crate) use self::window_actions::install_window_shortcuts;
use crate::application::{AppServices, WindowHost, WindowLaunch};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::session_context::SessionContext;
use crate::ui::connect_dialog::ConnectSubmission;
use crate::ui::welcome_view::{WelcomeView, WelcomeViewInit, WelcomeViewOutput};
use crate::ui::workspace::{Workspace, WorkspaceInit, WorkspaceInput};
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
        install_window_shortcuts(self.upcast_ref());
        imp.prompt_presenter
            .replace(Some(crate::ui::credential_prompt::CredentialPromptPresenter::start(
                prompts, self,
            )));

        let guards = CloseGuards::new();
        let window = self.downgrade();
        guards.connect_window(
            self,
            move || window.upgrade().and_then(|window| window.workspace_handle()),
            SessionWindow::on_close_approved,
        );
        let _ = imp.close_guards.set(guards);
        imp.inhibitor
            .replace(Some(WindowInhibitor::new(ApplicationInhibit::new(self))));

        let welcome_input = input.clone();
        let welcome = WelcomeView::builder()
            .launch(WelcomeViewInit)
            .connect_receiver(move |_, out| {
                welcome_input.deliver(match out {
                    WelcomeViewOutput::OpenConnect => SessionWindowInput::OpenConnectDialog,
                    WelcomeViewOutput::OpenSaved(saved) => SessionWindowInput::OpenSaved(Box::new(saved)),
                    WelcomeViewOutput::Delete(id) => SessionWindowInput::DeleteConnection(id),
                    WelcomeViewOutput::Duplicate(saved) => SessionWindowInput::DuplicateConnection(Box::new(saved)),
                    WelcomeViewOutput::SetColor(id, color) => SessionWindowInput::SetConnectionColor(id, color),
                    WelcomeViewOutput::SetGroup(id, group) => SessionWindowInput::SetConnectionGroup(id, group),
                });
            });
        let picker = PickerPage::new(welcome.widget());
        let reset_input = input.clone();
        picker
            .banner()
            .connect_button_clicked(move |_| reset_input.deliver(SessionWindowInput::ResetConnectionList));
        imp.welcome.replace(Some(welcome));
        let _ = imp.picker.set(picker);
        let _ = imp.state.set(WindowState {
            services,
            host,
            context,
        });

        self.show_page(SessionPage::Picker);
        input.deliver(SessionWindowInput::ReloadConnections);
        match launch {
            WindowLaunch::Picker => {}
            WindowLaunch::Connect(saved) => input.deliver(SessionWindowInput::OpenSaved(saved)),
            WindowLaunch::OpenFile(file) => input.deliver(SessionWindowInput::OpenFile(file)),
        }
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

    /// Whether the window holds logout back now.
    pub(crate) fn is_inhibiting(&self) -> bool {
        self.imp()
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
        if let Some(presenter) = imp.prompt_presenter.take() {
            presenter.abort();
        }
        self.release_session();
        drop(imp.dialog.take());
        drop(imp.welcome.take());
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

    /// The page's workspace, while the window shows one.
    pub(crate) fn workspace(&self) -> Option<Workspace> {
        match &*self.imp().page.try_borrow().ok()? {
            SessionPage::Workspace { workspace, .. } => Some(workspace.clone()),
            _ => None,
        }
    }

    fn workspace_handle(&self) -> Option<WorkspaceHandle> {
        self.workspace().and_then(|workspace| workspace.handle())
    }

    fn handle_input(&self, message: SessionWindowInput) {
        match message {
            SessionWindowInput::OpenSaved(saved) => self.on_open_saved(*saved),
            SessionWindowInput::OpenFile(file) => self.on_open_file(file),
            SessionWindowInput::FileResolved(resolved) => self.on_file_resolved(*resolved),
            SessionWindowInput::OpenConnectDialog => self.present_connect_dialog(None, None),
            SessionWindowInput::ConnectFromDialog(submission) => self.on_connect_from_dialog(*submission),
            SessionWindowInput::DialogClosed => drop(self.imp().dialog.take()),
            SessionWindowInput::CancelConnect => self.on_cancel_connect(),
            SessionWindowInput::RetryConnect => self.on_retry_connect(),
            SessionWindowInput::RetryWithNewSecret(kind) => self.on_retry_with_new_secret(kind),
            SessionWindowInput::EditConnection => self.on_edit_connection(),
            SessionWindowInput::Disconnect => self.on_disconnect(),
            SessionWindowInput::TeardownApproved => {
                if self.tear_down() {
                    self.show_page(SessionPage::Picker);
                    tracing::info!("disconnected");
                }
            }
            SessionWindowInput::CloseCurrent => self.on_close_current(),
            SessionWindowInput::Reconnect => {
                if let SessionPage::Workspace { session, .. } = &*self.imp().page.borrow() {
                    session.signal(MonitorSignal::RetryNow);
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
            SessionWindowInput::DirtyChanged(dirty) => {
                if self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
                    self.imp().dirty.set(dirty);
                    self.refresh_inhibitor();
                }
            }
            SessionWindowInput::SavesInFlightChanged(count) => {
                if self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
                    self.imp().saving.set(count > 0);
                    self.refresh_inhibitor();
                }
            }
            SessionWindowInput::TitleChanged(title) => {
                if self.page_is(|page| matches!(page, SessionPage::Workspace { .. })) {
                    self.set_title(Some(&title));
                }
            }
            SessionWindowInput::Command(command) => match *command {
                SessionWindowCommand::Attempt { generation, result } => self.on_attempt(generation, result),
            },
            SessionWindowInput::ReloadConnections => self.on_reload_connections(),
            SessionWindowInput::ConnectionsLoaded(connections) => self.on_connections_loaded(connections),
            SessionWindowInput::ConnectionListUnavailable => self.show_connection_list_banner(),
            SessionWindowInput::ResetConnectionList => self.on_reset_connection_list(),
            SessionWindowInput::SecretDeleteFailed(id, options) => self.on_secret_delete_failed(id, options),
            SessionWindowInput::DeleteConnection(id) => self.on_delete_connection(id),
            SessionWindowInput::ConfirmDelete(id, options) => self.on_confirm_delete(id, options),
            SessionWindowInput::DuplicateConnection(saved) => self.on_duplicate_connection(*saved),
            SessionWindowInput::SetConnectionColor(id, color) => self.on_set_connection_color(id, color),
            SessionWindowInput::SetConnectionGroup(id, group) => self.on_set_connection_group(id, group),
            SessionWindowInput::ExportConnections => self.on_export_connections(),
            SessionWindowInput::ImportConnections => self.on_import_connections(),
            SessionWindowInput::ConnectionsFileRead { path, bytes } => self.on_connections_file_read(path, bytes),
            SessionWindowInput::ShowToast(message) => self.show_toast(&message),
        }
    }

    fn show_toast(&self, message: &str) {
        self.add_toast(adw::Toast::new(message));
    }

    fn add_toast(&self, toast: adw::Toast) {
        #[cfg(test)]
        self.imp().toasts.borrow_mut().push(toast.clone());
        self.imp().toast_overlay.add_toast(toast);
    }

    /// Move to `page`. The page left behind drops with what it held,
    /// which releases a claim. A workspace left behind is torn down
    /// first, so its session is closed rather than cut off.
    fn show_page(&self, page: SessionPage) {
        self.tear_down();
        let imp = self.imp();
        let child: Option<gtk::Widget> = match &page {
            SessionPage::Picker => {
                self.set_title(Some(&crate::i18n::gettext("TablePro")));
                imp.picker.get().map(|picker| picker.clone().upcast())
            }
            SessionPage::Connecting { source, .. } => Some(ConnectingPage::new(&source_name(source)).upcast()),
            SessionPage::ConnectFailed { source, failure, .. } => Some(
                ConnectFailedPage::new(
                    &failure.message,
                    edit_label(source, failure).as_deref(),
                    failure.reenter,
                )
                .upcast(),
            ),
            SessionPage::Workspace { workspace, .. } => Some(workspace.clone().upcast()),
        };
        let editable = match &page {
            SessionPage::ConnectFailed { source, .. } => is_editable(source),
            _ => false,
        };
        window_actions::sync(self.upcast_ref(), &page, editable);
        let left = imp.page.replace(page);
        imp.toast_overlay.set_child(child.as_ref());
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
        let current =
            imp.attempts.accepts(generation) && self.page_is(|page| matches!(page, SessionPage::Connecting { .. }));
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
                drop(claim);
                self.show_page(SessionPage::Picker);
            }
            Err(AttemptError::Failed(failure)) => {
                tracing::warn!(error = %failure.message, "connect failed");
                self.show_page(SessionPage::ConnectFailed { claim, source, failure });
            }
        }
    }

    /// Start the session that connected and build its workspace.
    fn adopt(&self, claim: SessionClaim, source: ConnectSource, connected: Connected) {
        let Connected {
            pending,
            saved,
            warnings,
        } = connected;
        let (Some(state), Some(guards)) = (self.state(), self.close_guards()) else {
            self.discard_pending(pending);
            return;
        };
        let key = claim.key().clone();
        let credentials = state.context.credentials_for(saved.as_ref());
        let session = Session::start(pending, state.context.session_deps(credentials));
        claim.attach(&session);
        if let ConnectSource::Intent(intent) = &source
            && let Err(error) = state
                .services
                .settings
                .set_connect_dialog_driver(&intent.request.metadata.driver_id)
        {
            tracing::warn!(%error, "could not remember the connect dialog driver");
        }
        let workspace = Workspace::new(WorkspaceInit {
            key: key.clone(),
            session: session.clone(),
            services: state.services.clone(),
            context: state.context.clone(),
            window: self.clone().upcast(),
            close_guards: guards.clone(),
        });
        self.connect_workspace(&workspace);
        self.show_page(SessionPage::Workspace {
            claim,
            session,
            workspace: workspace.clone(),
        });
        workspace.start();
        drop(self.imp().dialog.take());
        for warning in warnings {
            self.show_toast(&warning);
        }
        if let SessionKey::Saved(id) = key {
            self.touch_last_opened(id);
        }
    }

    fn connect_workspace(&self, workspace: &Workspace) {
        let Some(input) = self.input() else {
            return;
        };
        let dirty = input.clone();
        workspace.connect_dirty_changed(move |_, value| dirty.deliver(SessionWindowInput::DirtyChanged(value)));
        let saves = input.clone();
        workspace.connect_saves_in_flight_changed(move |_, count| {
            saves.deliver(SessionWindowInput::SavesInFlightChanged(count));
        });
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
        match state.context.sessions.claim(key, self.id()) {
            Ok(claim) => Some(claim),
            Err(ClaimError::AlreadyOpen { window_id }) => {
                self.present_owner(window_id);
                None
            }
        }
    }

    fn present_owner(&self, window_id: u32) {
        let presented = self.state().is_some_and(|state| state.host.present_window(window_id));
        if !presented {
            self.show_toast(&crate::i18n::gettext(
                "This connection is already open in another window.",
            ));
        }
    }

    fn on_open_saved(&self, saved: SavedConnection) {
        let Some(state) = self.state() else {
            return;
        };
        if !self.page_is(|page| matches!(page, SessionPage::Picker)) {
            // This window has its session; another one opens this.
            let key = SessionKey::Saved(saved.id);
            if let Some(owner) = state.context.sessions.window_for(&key)
                && state.host.present_window(owner)
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
        if !self.page_is(|page| matches!(page, SessionPage::Picker)) {
            state.host.open_window(WindowLaunch::OpenFile(file));
            return;
        }
        let path = file.path();
        let uri = file.uri().to_string();
        let resolving_uri = uri.clone();
        let connections = state.services.storage.connections().clone();
        let resolving = state
            .services
            .tasks
            .spawn_blocking_task(move || resolve_file_blocking(path, resolving_uri, &connections));
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
        let ResolvedFile { uri, target } = resolved;
        if !self.page_is(|page| matches!(page, SessionPage::Picker)) {
            if let Some(state) = self.state() {
                state.host.open_window(WindowLaunch::OpenFile(gio::File::for_uri(&uri)));
            }
            return;
        }
        match target {
            Ok(FileTarget::Saved(saved)) => self.on_open_saved(*saved),
            Ok(FileTarget::File(identity)) => {
                if let Some(claim) = self.claim(SessionKey::File(identity.uri.clone())) {
                    self.begin_connect(claim, ConnectSource::File(identity));
                }
            }
            Err(error) => {
                tracing::warn!(%error, %uri, "could not open the file");
                let Some(claim) = self.claim(SessionKey::File(uri.clone())) else {
                    return;
                };
                let failure = ConnectFailure::new(file_failure_message(&uri, &error));
                self.show_page(SessionPage::ConnectFailed {
                    claim,
                    source: ConnectSource::File(FileIdentity::new(None, uri)),
                    failure,
                });
            }
        }
    }

    fn on_connect_from_dialog(&self, submission: ConnectSubmission) {
        let ConnectSubmission { request, pending_save } = submission;
        match &*self.imp().page.borrow() {
            SessionPage::Picker | SessionPage::ConnectFailed { .. } => {}
            SessionPage::Connecting { .. } | SessionPage::Workspace { .. } => {
                tracing::warn!("a connect from the dialog reached a window with a session");
                return;
            }
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
                self.present_owner(window_id);
            }
        }
    }

    fn begin_connect(&self, claim: SessionClaim, source: ConnectSource) {
        self.begin_connect_with(claim, source, CredentialDemand::default());
    }

    fn begin_connect_with(&self, claim: SessionClaim, source: ConnectSource, demand: CredentialDemand) {
        let Some(state) = self.state() else {
            return;
        };
        let ticket = self.imp().attempts.begin();
        let generation = ticket.generation();
        let cancel = ticket.cancel().clone();
        let work = connect_work(state, &source, demand, cancel);
        self.show_page(SessionPage::Connecting { claim, source });
        let input = self.input();
        let (tasks, hold) = (state.services.tasks.clone(), state.services.hold());
        crate::runtime::spawn_and_deliver(&state.services.tasks, work, move |outcome| {
            let result = outcome.unwrap_or_else(|failure| {
                Err(AttemptError::Failed(ConnectFailure::new(
                    crate::ui::error_text::task_failure_message(&failure),
                )))
            });
            let attempt = SessionWindowCommand::Attempt { generation, result };
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
            self.show_page(SessionPage::Picker);
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

    fn on_edit_connection(&self) {
        let prefill = match &*self.imp().page.borrow() {
            SessionPage::ConnectFailed { source, failure, .. } => connections::prefill_for(source)
                .map(|prefill| (prefill, failure.remedy.map(crate::ui::connect_dialog::remedy_field))),
            _ => None,
        };
        if let Some((prefill, focus)) = prefill {
            self.present_connect_dialog(Some(prefill), focus);
        }
    }

    fn on_disconnect(&self) {
        let (Some(handle), Some(guards)) = (self.workspace_handle(), self.close_guards()) else {
            return;
        };
        guards.begin_teardown();
        if guards.may_tear_down(&handle) {
            self.send(SessionWindowInput::TeardownApproved);
            return;
        }
        let input = self.input();
        guards.ask_tear_down(self.upcast_ref(), &handle, move |decision| {
            if decision == CloseDecision::Approved
                && let Some(input) = input
            {
                input.deliver(SessionWindowInput::TeardownApproved);
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
        drop(left);
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

/// Supersede the connect in flight, not only cancel it: a driver
/// blocked in a socket call can still connect afterwards, and that late
/// session must not be adopted.
fn stop_connecting(attempts: &tablepro_session::ConnectAttempts) {
    drop(attempts.begin());
    attempts.cancel();
}

/// The connect a source makes, off the GTK thread. Reading the keyring,
/// asking for what it lacks and connecting all happen there; only the
/// outcome comes back.
fn connect_work(
    state: &WindowState,
    source: &ConnectSource,
    demand: CredentialDemand,
    cancel: tokio_util::sync::CancellationToken,
) -> BoxFuture<'static, Result<Connected, AttemptError>> {
    let context = &state.context;
    let connector = context.connector.clone();
    let interaction = context.attended();
    match source {
        ConnectSource::Saved(saved) => {
            let saved = (**saved).clone();
            let drivers = context.drivers.clone();
            let credentials = context.credentials_for(Some(&saved));
            async move {
                let connected = connect_flow::connect_saved(
                    &saved,
                    &drivers,
                    &*credentials,
                    &*connector,
                    interaction,
                    demand,
                    cancel,
                )
                .await;
                match connected {
                    Ok((pending, refused)) => Ok(Connected {
                        pending,
                        saved: Some(saved),
                        warnings: refused
                            .iter()
                            .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                            .collect(),
                    }),
                    Err(error) => Err(match attempt_error(&error) {
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
        ConnectSource::Intent(intent) => {
            let request = intent.request.clone();
            let Some(pending_save) = intent.pending_save.clone() else {
                return async move {
                    connect_flow::connect_request(&*connector, request, interaction, cancel)
                        .await
                        .map(|pending| Connected {
                            pending,
                            saved: None,
                            warnings: Vec::new(),
                        })
                        .map_err(|error| attempt_error(&error))
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
                        saved: Some(report.saved),
                    }),
                    Err(connect_flow::SubmitError::Connect(error)) => Err(attempt_error(&error)),
                    Err(connect_flow::SubmitError::Save(error)) => {
                        Err(AttemptError::Failed(ConnectFailure::new(crate::i18n::gettext_f(
                            "The connection could not be saved: {error}",
                            &[("error", &error.to_string())],
                        ))))
                    }
                }
            }
            .boxed()
        }
        ConnectSource::File(identity) => {
            let request = resolve_file_identity::file_request(identity, &context.drivers);
            async move {
                let request = request.map_err(|error| attempt_error(&error))?;
                connect_flow::connect_request(&*connector, request, interaction, cancel)
                    .await
                    .map(|pending| Connected {
                        pending,
                        saved: None,
                        warnings: Vec::new(),
                    })
                    .map_err(|error| attempt_error(&error))
            }
            .boxed()
        }
    }
}

fn attempt_error(error: &ConnectError) -> AttemptError {
    match error {
        ConnectError::Cancelled => AttemptError::Cancelled,
        error => AttemptError::Failed(ConnectFailure {
            message: crate::ui::error_text::connect_error_message(error),
            remedy: crate::ui::error_text::connect_remedy(error),
            reenter: None,
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

/// Only a connection the connect dialog shows can be edited from a
/// failed connect.
fn is_editable(source: &ConnectSource) -> bool {
    matches!(source, ConnectSource::Saved(_) | ConnectSource::Intent(_))
}

/// The failed page's Edit button: named after the setting that fixes a
/// TLS failure when there is one.
fn edit_label(source: &ConnectSource, failure: &ConnectFailure) -> Option<String> {
    is_editable(source).then(|| {
        failure
            .remedy
            .map_or_else(|| crate::i18n::gettext("Edit Connection…"), |remedy| remedy.label())
    })
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
