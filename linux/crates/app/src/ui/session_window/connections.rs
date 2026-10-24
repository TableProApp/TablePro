//! The saved connections a window's picker lists, and the connect
//! dialog that adds to them.

use gtk4 as gtk;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::SafeModeLevel;
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::{ConnectSource, PendingSave, RequestTarget, SessionKey};
use tablepro_storage::{
    ConnectionColor, ConnectionGroupName, ConnectionListState, ConnectionTag, ConnectionTagName, SavedConnection,
};
use uuid::Uuid;

use super::session_page::SessionPage;
use super::{SessionWindow, SessionWindowInput};
use crate::runtime::{DeliverInput, InputSender};
use crate::services::connection_deletion::DeletionOptions;
use crate::services::deletion_error::DeletionError;
use crate::services::saved_connection_error::SavedConnectionError;
use crate::ui::connect_dialog::{ConnectDialog, ConnectDialogInit, ConnectDialogMode, ConnectPrefill, FormField};
use crate::ui::delete_connection_dialog::{self, DeleteConnectionDialog};
use crate::ui::file_read::{FileReadError, read_capped_file};
use crate::ui::ssh_inputs::SshEnvironment;
use crate::ui::workspace::WorkspaceInput;
use crate::workspace::CloseDecision;

/// The password the user typed, so editing after a failure does not
/// make them type it again. It stays in memory.
fn typed_password(target: &RequestTarget) -> Option<secrecy::SecretString> {
    match target {
        RequestTarget::Network {
            credentials: tablepro_core::Credentials::Password { password, .. },
            ..
        } => Some(password.clone()),
        _ => None,
    }
}

/// What the connect dialog reopens on after a connect from it failed:
/// the connection as it was submitted, with the password typed for it.
pub(super) fn prefill_for(source: &ConnectSource) -> Option<ConnectPrefill> {
    match source {
        ConnectSource::Intent(intent) => intent.pending_save.as_ref().map(|save| ConnectPrefill {
            connection: save.connection.clone(),
            password: typed_password(&intent.request.target),
        }),
        ConnectSource::Saved(_) | ConnectSource::File(_) => None,
    }
}

impl SessionWindow {
    /// Show the connect dialog over this window for `mode`, filled from
    /// `prefill` when a connect from it failed, with the focus on
    /// `focus`. It opens once the user's SSH keys are looked for, which
    /// reads the disk and so runs off the GTK thread.
    pub(super) fn present_connect_dialog(
        &self,
        mode: ConnectDialogMode,
        prefill: Option<ConnectPrefill>,
        focus: Option<FormField>,
    ) {
        let Some(state) = self.state() else {
            return;
        };
        // A second request while the first waits would stack two dialogs.
        if self.imp().dialog_opening.replace(true) {
            return;
        }
        let detecting = state
            .services
            .tasks
            .spawn_blocking_task(SshEnvironment::detect_blocking);
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let environment = detecting.await.unwrap_or_else(|failure| {
                tracing::warn!(%failure, "could not look for SSH keys");
                SshEnvironment::default()
            });
            if let Some(window) = window.upgrade() {
                window.imp().dialog_opening.set(false);
                window.show_connect_dialog(mode, prefill, focus, environment);
            }
        });
    }

    fn show_connect_dialog(
        &self,
        mode: ConnectDialogMode,
        prefill: Option<ConnectPrefill>,
        focus: Option<FormField>,
        ssh: SshEnvironment,
    ) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        if self.imp().shut_down.get() {
            return;
        }
        let context = &state.context;
        let dialog = ConnectDialog::new(ConnectDialogInit {
            drivers: context.drivers.clone(),
            connector: context.connector.clone(),
            interaction: context.attended(),
            tasks: state.services.tasks.clone(),
            saved_connections: state.services.saved_connections.connections(),
            tags: state.services.saved_connections.tags(),
            remembered_driver: state.services.settings.connect_dialog_driver(),
            ai_assistant: state.services.settings.ai_provider().is_some(),
            ssh_environment: ssh,
            prefill,
            mode,
            editor: state.services.saved_connection_editor.clone(),
            credentials: context.credentials.clone(),
            hold: state.services.hold(),
        });
        let submitted = input.clone();
        dialog.connect_submitted(move |_, submission| {
            submitted.deliver(SessionWindowInput::ConnectFromDialog(Box::new(submission)));
        });
        let saved = input.clone();
        dialog.connect_saved(move |_, id| saved.deliver(SessionWindowInput::ConnectionSaved(id)));
        dialog.connect_closed(move |_| input.deliver(SessionWindowInput::DialogClosed));
        dialog.present(Some(self));
        if let Some(field) = focus {
            dialog.reveal_field(field);
        }
        self.imp().dialog.replace(Some(dialog));
    }

    /// Keep the dialog's edits to a connection open in another window,
    /// for its next connect. The keyring is written first, so a secret
    /// it refuses is reported rather than lost without a word.
    pub(super) fn persist_pending_save(&self, save: PendingSave) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let secrets = state.context.secrets.clone();
        let writes = StoreConnectionWrites::new(
            state.services.storage.connections().clone(),
            state.services.tasks.clone(),
        );
        crate::runtime::spawn_held(&state.services.tasks, &*state.services.hold(), async move {
            match tablepro_session::persist_pending_save(&*secrets, &writes, save).await {
                Ok(report) => {
                    for (_, error) in &report.secret_failures {
                        input.deliver(SessionWindowInput::ShowToast(
                            crate::services::secret_save_report::not_saved_message(error),
                        ));
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "could not save the edited connection");
                    input.deliver(SessionWindowInput::ShowToast(crate::i18n::gettext_f(
                        "The connection could not be saved. {reason}",
                        &[(
                            "reason",
                            &crate::ui::error_text::saved_connection_error_message(&SavedConnectionError::Storage(
                                error,
                            )),
                        )],
                    )));
                }
            }
        });
    }

    /// Stamp the connection's last-opened time, which every picker sorts
    /// by once the store publishes the list with it.
    pub(super) fn touch_last_opened(&self, id: Uuid) {
        let Some(state) = self.state() else {
            return;
        };
        let connections = state.services.storage.connections().clone();
        let hold = state.services.hold().acquire();
        let touching = state
            .services
            .tasks
            .spawn_blocking_task(move || connections.touch_last_opened_blocking(id));
        glib::spawn_future_local(async move {
            match touching.await {
                Ok(Err(error)) => tracing::warn!(%error, "could not stamp the last-opened time"),
                Err(error) => tracing::warn!(%error, "the last-opened task failed"),
                Ok(Ok(())) => {}
            }
            drop(hold);
        });
    }

    /// Read the connection list, once per process: the store publishes
    /// it, and every picker follows the store from then on.
    pub(super) fn on_load_connections(&self) {
        let Some(state) = self.state() else {
            return;
        };
        let store = state.services.storage.connections().clone();
        let reading = state.services.tasks.spawn_blocking_task(move || store.load_blocking());
        glib::spawn_future_local(async move {
            match reading.await {
                Ok(Ok(_)) => {}
                Ok(Err(error)) => tracing::warn!(%error, "the saved connections could not be read"),
                Err(failure) => tracing::warn!(%failure, "the connections read task failed"),
            }
        });
    }

    /// `saved` as the connection list holds it now, or `None` once it is
    /// deleted. The list every window shares is read without touching
    /// the disk; before it is first read, `saved` is all there is.
    pub(super) fn saved_as_stored(&self, saved: &SavedConnection) -> Option<SavedConnection> {
        let Some(state) = self.state() else {
            return Some(saved.clone());
        };
        match state.services.storage.connections().snapshot().state {
            ConnectionListState::Ready(list) => list.connections.iter().find(|entry| entry.id == saved.id).cloned(),
            ConnectionListState::Loading | ConnectionListState::Unavailable(_) => Some(saved.clone()),
        }
    }

    fn saved_connection(&self, id: Uuid) -> Option<SavedConnection> {
        self.state()?.services.saved_connections.get(id)
    }

    /// The name a dialog or toast calls a saved connection by.
    fn connection_name(&self, id: Uuid) -> String {
        self.saved_connection(id)
            .map_or_else(|| crate::i18n::gettext("this connection"), |saved| saved.name)
    }

    /// Ask before deleting: the delete takes the keyring secrets with it
    /// and has no undo, so it asks whatever the preferences say.
    pub(super) fn on_delete_connection(&self, id: Uuid) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let name = self.connection_name(id);
        if self.offer_open_window(id, &name) {
            return;
        }
        let asking = DeleteConnectionDialog::new(&name);
        let history = state.services.history();
        let tasks = state.services.tasks.clone();
        let counting = asking.clone();
        glib::spawn_future_local(async move {
            let Some(store) = history.ready_store().await else {
                counting.show_history_unavailable();
                return;
            };
            match tasks
                .spawn_task(async move { store.count_for_connection(id).await })
                .await
            {
                Ok(Ok(count)) => counting.show_history_count(count),
                Ok(Err(error)) => tracing::warn!(%error, "could not count the connection's query history"),
                Err(failure) => tracing::warn!(%failure, "the query history count did not finish"),
            }
        });
        asking.connect_delete(move |options| input.deliver(SessionWindowInput::ConfirmDelete(id, options)));
        asking.dialog.present(Some(self));
    }

    /// A connection open in a window, or connecting in one, is not
    /// deleted from under it: the user is offered that window instead.
    /// True when it is open.
    fn offer_open_window(&self, id: Uuid, name: &str) -> bool {
        let Some(state) = self.state() else {
            return false;
        };
        let Some(owner) = state.context.sessions.window_for(&SessionKey::Saved(id)) else {
            return false;
        };
        let dialog = delete_connection_dialog::is_open_dialog(name);
        let host = state.host.clone();
        dialog.connect_response(Some(delete_connection_dialog::SHOW), move |_, _| {
            if !host.present_window(owner) {
                tracing::warn!(owner, "the window holding the connection is gone");
            }
        });
        dialog.present(Some(self));
        true
    }

    /// Delete a saved connection the user confirmed, under a hold so a
    /// quit right after it does not cut it off between the keyring and
    /// the list.
    ///
    /// The delete claims the connection's key until it ends, so a
    /// connect started meanwhile from a picker that still lists it is
    /// refused rather than given an entry whose tabs are being purged.
    pub(super) fn on_confirm_delete(&self, id: Uuid, options: DeletionOptions) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let name = self.connection_name(id);
        // It may have been opened since the dialog asked.
        let Ok(claim) = state.context.sessions.claim(SessionKey::Saved(id), self.id()) else {
            self.offer_open_window(id, &name);
            return;
        };
        let services = state.services.clone();
        let hold = services.hold().acquire();
        glib::spawn_future_local(async move {
            let history = services.history().ready_store().await;
            match services.connection_deletion(history).run(id, options).await {
                Ok(report) if report.is_complete() => {}
                Ok(report) => {
                    for failure in &report.purge_failures {
                        tracing::warn!(%failure, "kept something stored for a deleted connection");
                    }
                    if let Some(summary) = report.summary(&name) {
                        input.deliver(SessionWindowInput::ShowToast(summary));
                    }
                }
                Err(DeletionError::Secrets(error)) => {
                    tracing::warn!(%error, "could not delete the connection's secrets; keeping the entry");
                    input.deliver(SessionWindowInput::SecretDeleteFailed(id, options));
                }
                Err(error) => {
                    tracing::warn!(%error, "could not delete the connection");
                    input.deliver(SessionWindowInput::ShowToast(error.summary(&name)));
                }
            }
            drop(claim);
            drop(hold);
        });
    }

    /// Open the connect dialog on the saved connection `id` to change
    /// it, as the list holds it now.
    pub(super) fn on_edit_saved_connection(&self, id: Uuid) {
        match self.saved_connection(id) {
            Some(saved) => self.present_connect_dialog(ConnectDialogMode::Edit(Box::new(saved)), None, None),
            None => self.show_toast(&crate::i18n::gettext("The connection was deleted.")),
        }
    }

    /// An edit was saved. A connect that failed here tries again with
    /// it; a session open on the connection keeps what it connected
    /// with, since an edit never moves a live session to another server.
    pub(super) fn on_connection_saved(&self, id: Uuid) {
        let key = SessionKey::Saved(id);
        if self.page_is(|page| matches!(page, SessionPage::ConnectFailed { claim, .. } if *claim.key() == key)) {
            self.on_retry_connect();
            return;
        }
        let Some(state) = self.state() else {
            return;
        };
        if state.context.sessions.window_for(&key).is_some() {
            self.show_toast(&crate::i18n::gettext("Changes apply the next time you connect"));
        }
    }

    /// Copy a saved connection so a second database on the same server
    /// does not have to be typed out again, then put the focus on the
    /// copy, which sorts among the connections never opened.
    pub(super) fn on_duplicate_connection(&self, id: Uuid) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        let hold = state.services.hold().acquire();
        let window = self.downgrade();
        crate::runtime::spawn_and_deliver(
            &state.services.tasks,
            async move { editor.duplicate(id).await },
            move |outcome| {
                drop(hold);
                let Some(window) = window.upgrade() else {
                    return;
                };
                match flatten(outcome) {
                    Ok(copy) => {
                        if let Some(welcome) = window.imp().welcome.borrow().as_ref() {
                            welcome.focus_connection(copy.id);
                        }
                    }
                    Err(error) => window.show_saved_connection_error(
                        |reason| {
                            crate::i18n::gettext_f(
                                "The connection could not be duplicated. {reason}",
                                &[("reason", reason)],
                            )
                        },
                        &error,
                    ),
                }
            },
        );
    }

    /// File a connection under a group, or take it out of the one it
    /// is in.
    pub(super) fn on_set_connection_group(&self, id: Uuid, group: Option<ConnectionGroupName>) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(async move { editor.move_to_group(id, group).await }, |reason| {
            crate::i18n::gettext_f("The group could not be saved. {reason}", &[("reason", reason)])
        });
    }

    /// Put a colour on a connection, or take the one it has off.
    pub(super) fn on_set_connection_color(&self, id: Uuid, color: Option<ConnectionColor>) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(async move { editor.set_color(id, color).await }, |reason| {
            crate::i18n::gettext_f("The colour could not be saved. {reason}", &[("reason", reason)])
        });
    }

    pub(super) fn on_set_connection_tag(&self, id: Uuid, tag: Uuid, carried: bool) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(async move { editor.set_tag(id, tag, carried).await }, |reason| {
            crate::i18n::gettext_f("The tag could not be saved. {reason}", &[("reason", reason)])
        });
    }

    pub(super) fn on_create_tag(&self, name: ConnectionTagName, color: ConnectionColor, on: Option<Uuid>) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(
            async move { editor.create_tag(name, color, on).await.map(drop) },
            |reason| crate::i18n::gettext_f("The tag could not be created. {reason}", &[("reason", reason)]),
        );
    }

    pub(super) fn on_update_tag(&self, tag: ConnectionTag) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(async move { editor.update_tag(tag).await }, |reason| {
            crate::i18n::gettext_f("The tag could not be saved. {reason}", &[("reason", reason)])
        });
    }

    pub(super) fn on_delete_tag(&self, id: Uuid) {
        let Some(state) = self.state() else {
            return;
        };
        let editor = state.services.saved_connection_editor.clone();
        self.change_connection(async move { editor.delete_tag(id).await }, |reason| {
            crate::i18n::gettext_f("The tag could not be deleted. {reason}", &[("reason", reason)])
        });
    }

    /// One Manage Tags per window: a second ask brings the open one back.
    pub(super) fn on_manage_tags(&self) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        if let Some(open) = self.imp().manage_tags.borrow().as_ref() {
            open.dialog.present(Some(self));
            return;
        }
        let manage = crate::ui::tags::ManageTagsDialog::new(state.services.saved_connections.clone(), input);
        let window = self.downgrade();
        manage.dialog.connect_closed(move |_| {
            if let Some(window) = window.upgrade() {
                window.imp().manage_tags.take();
            }
        });
        manage.dialog.present(Some(self));
        self.imp().manage_tags.replace(Some(manage));
    }

    /// Move the session on screen to `level`, and the saved connection
    /// with it. A level on the other side of Read-Only needs the
    /// connection opened again, so the window reconnects once the tabs
    /// may go; until then the saved level waits for the next connect.
    pub(super) fn on_set_safe_mode(&self, level: SafeModeLevel) {
        let (key, session) = match &*self.imp().page.borrow() {
            SessionPage::Workspace { claim, session, .. } => (claim.key().clone(), session.clone()),
            _ => return,
        };
        let saved = match key {
            SessionKey::Saved(id) => self.stored_connection(id),
            SessionKey::File(_) => None,
        };
        // The saved level can differ from the session's after a reconnect
        // was declined, and a level still being written can land after
        // this choice unless this one is written after it.
        let differs = session.safe_mode() != level
            || self.imp().level_saving.get()
            || saved.as_ref().is_some_and(|saved| saved.safe_mode != level);
        if differs {
            let applied = session.safe_mode() == level || session.set_safe_mode(level);
            match (saved.map(|saved| saved.id), applied) {
                (Some(id), _) => self.save_safe_mode(LevelSave {
                    id,
                    level,
                    reopen: !applied,
                }),
                (None, true) => {}
                (None, false) => self.show_toast(&crate::i18n::gettext(
                    "Save this connection to change it to or from Read-Only while it is open.",
                )),
            }
        }
        self.show_safe_mode();
    }

    /// The saved connection `id` as the list on disk holds it now.
    fn stored_connection(&self, id: Uuid) -> Option<SavedConnection> {
        match self.state()?.services.storage.connections().snapshot().state {
            ConnectionListState::Ready(list) => list.connections.iter().find(|entry| entry.id == id).cloned(),
            ConnectionListState::Loading | ConnectionListState::Unavailable(_) => None,
        }
    }

    /// Writes run one at a time, in the order chosen.
    fn save_safe_mode(&self, save: LevelSave) {
        let Some(state) = self.state() else {
            return;
        };
        let imp = self.imp();
        if imp.level_saving.replace(true) {
            imp.level_next.set(Some(save));
            return;
        }
        let LevelSave { id, level, reopen } = save;
        let editor = state.services.saved_connection_editor.clone();
        let hold = state.services.hold().acquire();
        let window = self.downgrade();
        let saving = async move { editor.set_safe_mode(id, level).await };
        crate::runtime::spawn_and_deliver(&state.services.tasks, saving, move |outcome| {
            drop(hold);
            let Some(window) = window.upgrade() else {
                return;
            };
            window.imp().level_saving.set(false);
            if let Some(next) = window.imp().level_next.take() {
                window.save_safe_mode(next);
                return;
            }
            match flatten(outcome) {
                Ok(()) if reopen => window.reopen_after_teardown(id),
                Ok(()) => {}
                Err(error) => window.show_saved_connection_error(
                    |reason| crate::i18n::gettext_f("Safe Mode could not be saved. {reason}", &[("reason", reason)]),
                    &error,
                ),
            }
        });
    }

    /// Ask the tabs, as Disconnect does, then connect again.
    fn reopen_after_teardown(&self, id: Uuid) {
        let (Some(handle), Some(guards), Some(input)) = (self.workspace_handle(), self.close_guards(), self.input())
        else {
            return;
        };
        if !self.page_is(
            |page| matches!(page, SessionPage::Workspace { claim, .. } if *claim.key() == SessionKey::Saved(id)),
        ) {
            return;
        }
        guards.begin_teardown();
        if guards.may_tear_down(&handle) {
            input.deliver(SessionWindowInput::ReopenApproved(id));
            return;
        }
        let window = self.downgrade();
        guards.ask_tear_down(self.upcast_ref(), &handle, move |decision| match decision {
            CloseDecision::Approved => input.deliver(SessionWindowInput::ReopenApproved(id)),
            _ => {
                if let Some(window) = window.upgrade() {
                    window.show_toast(&crate::i18n::gettext("Changes apply the next time you connect"));
                }
            }
        });
    }

    pub(super) fn on_reopen_approved(&self, id: Uuid) {
        let stored = self.stored_connection(id);
        if !self.tear_down() {
            return;
        }
        self.show_page(SessionPage::Picker);
        match stored {
            Some(saved) => self.on_open_saved(saved),
            None => self.show_toast(&crate::i18n::gettext("The connection was deleted.")),
        }
    }

    /// Tick the session's level in the main menu and name it in the
    /// title.
    pub(super) fn show_safe_mode(&self) {
        let level = match &*self.imp().page.borrow() {
            SessionPage::Workspace { session, .. } => Some(session.safe_mode()),
            _ => None,
        };
        super::window_actions::show_safe_mode(self.upcast_ref(), level);
        if let Some(input) = self.workspace().and_then(|workspace| workspace.input()) {
            input.deliver(WorkspaceInput::SafeModeChanged);
        }
    }

    /// Run a change to a saved connection, holding the process until it
    /// lands so a quit right after it keeps it. Every picker redraws
    /// from the list the store then publishes.
    fn change_connection(
        &self,
        change: impl std::future::Future<Output = Result<(), SavedConnectionError>> + Send + 'static,
        failure: fn(&str) -> String,
    ) {
        let Some(state) = self.state() else {
            return;
        };
        let hold = state.services.hold().acquire();
        let window = self.downgrade();
        crate::runtime::spawn_and_deliver(&state.services.tasks, change, move |outcome| {
            drop(hold);
            if let (Err(error), Some(window)) = (flatten(outcome), window.upgrade()) {
                window.show_saved_connection_error(failure, &error);
            }
        });
    }

    /// Say a change did not happen, with `failure` putting the reason
    /// where the translation wants it.
    fn show_saved_connection_error(&self, failure: fn(&str) -> String, error: &SavedConnectionError) {
        tracing::warn!(%error, "a change to a saved connection did not happen");
        self.show_toast(&failure(&crate::ui::error_text::saved_connection_error_message(error)));
    }

    /// Write the connection list to a file the user picks.
    ///
    /// The file carries no passwords, and the dialog's name says what
    /// it does carry, because it is going somewhere the keyring does
    /// not protect.
    pub(super) fn on_export_connections(&self) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let connections = state.services.storage.connections().clone();
        let reading = state
            .services
            .tasks
            .spawn_blocking_task(move || connections.export_blocking());
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let error = match reading.await {
                Ok(Ok(bytes)) => {
                    if let Some(window) = window.upgrade() {
                        ask_where_to_export(&window, bytes, input);
                    }
                    return;
                }
                Ok(Err(error)) => error.to_string(),
                Err(error) => error.to_string(),
            };
            tracing::warn!(%error, "could not read the connections to export");
            input.deliver(SessionWindowInput::ShowToast(crate::i18n::gettext(
                "The connections could not be read.",
            )));
        });
    }

    /// Ask for an exported file and read it off the GTK thread.
    pub(super) fn on_import_connections(&self) {
        let Some(input) = self.input() else {
            return;
        };
        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Import Connections"))
            .modal(true)
            .default_filter(&json_filter())
            .filters(&json_filters())
            .build();
        dialog.open(Some(self), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            glib::spawn_future_local(async move {
                let path = file.path().unwrap_or_default();
                input.deliver(match read_connections_file(&file).await {
                    Ok(bytes) => SessionWindowInput::ConnectionsFileRead { path, bytes },
                    Err(message) => SessionWindowInput::ShowToast(message),
                });
            });
        });
    }

    pub(super) fn on_connections_file_read(&self, path: std::path::PathBuf, bytes: Vec<u8>) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let connections = state.services.storage.connections().clone();
        let tasks = state.services.tasks.clone();
        let file = path.clone();
        crate::runtime::spawn_held(&state.services.tasks, &*state.services.hold(), async move {
            let imported = tasks
                .spawn_blocking_task(move || connections.import_blocking(&path, &bytes))
                .await;
            let message = match imported {
                Ok(Ok(report)) if report.total() == 0 => crate::i18n::gettext("That file has no connections in it."),
                Ok(Ok(report)) => crate::i18n::ngettext_f(
                    "Imported {n} connection.",
                    "Imported {n} connections.",
                    u32::try_from(report.total()).unwrap_or(u32::MAX),
                    &[("n", &report.total().to_string())],
                ),
                Ok(Err(error)) => {
                    tracing::warn!(%error, "could not import the connections");
                    import_failure_message(error, &file)
                }
                Err(error) => {
                    tracing::warn!(%error, "the import task did not finish");
                    crate::i18n::gettext("The connections could not be imported.")
                }
            };
            input.deliver(SessionWindowInput::ShowToast(message));
        });
    }

    /// The list could not be read, so the user is told rather than shown
    /// an empty picker that looks like their connections vanished.
    pub(super) fn show_connection_list_banner(&self) {
        let (Some(state), Some(picker)) = (self.state(), self.imp().picker.get()) else {
            return;
        };
        let banner = picker.banner();
        let Some(content) =
            crate::ui::connection_list_banner::banner_content(&state.services.saved_connections.state())
        else {
            banner.set_revealed(false);
            return;
        };
        banner.set_title(&content.title);
        banner.set_button_label(Some(&content.button_label));
        banner.set_revealed(true);
    }

    /// The keyring refused, so the entry stays and the user is offered
    /// another go rather than being left with orphaned secrets. Retry
    /// runs the delete they already confirmed.
    pub(super) fn on_secret_delete_failed(&self, id: Uuid, options: DeletionOptions) {
        let Some(input) = self.input() else {
            return;
        };
        let toast = crate::ui::plain_toast(&crate::i18n::gettext(
            "The stored passwords could not be deleted, so the connection was kept.",
        ));
        toast.set_button_label(Some(&crate::i18n::gettext("Retry")));
        toast.connect_button_clicked(move |_| input.deliver(SessionWindowInput::ConfirmDelete(id, options)));
        self.add_toast(toast);
    }

    pub(super) fn on_reset_connection_list(&self) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Reset Saved Connections?")),
            Some(&crate::i18n::gettext(
                "The unreadable file will be renamed so it can be recovered. Stored passwords stay in the keyring.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("reset", &crate::i18n::gettext("Reset"));
        dialog.set_response_appearance("reset", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let window = self.downgrade();
        dialog.connect_response(None, move |_, response| {
            if response == "reset"
                && let Some(window) = window.upgrade()
            {
                window.reset_connection_list();
            }
        });
        dialog.present(Some(self));
    }

    /// Move the unreadable list aside, holding the process until the
    /// rename lands so a quit right after Reset keeps it.
    pub(super) fn reset_connection_list(&self) {
        let (Some(state), Some(picker)) = (self.state(), self.imp().picker.get()) else {
            return;
        };
        let store = state.services.storage.connections().clone();
        let held = state.services.hold().acquire();
        let resetting = state
            .services
            .tasks
            .spawn_blocking_task(move || store.reset_unreadable_blocking(std::time::SystemTime::now()));
        let banner = picker.banner();
        let toasts = picker.toast_overlay();
        glib::spawn_future_local(async move {
            let reset = resetting.await;
            drop(held);
            let reason = match reset {
                Ok(Ok(moved)) => {
                    banner.set_revealed(false);
                    toasts.add_toast(crate::ui::plain_toast(
                        &crate::ui::connection_list_banner::reset_toast_text(&moved),
                    ));
                    return;
                }
                Ok(Err(error)) => {
                    tracing::warn!(%error, "could not reset the saved connections");
                    crate::ui::error_text::storage_io_message(&error)
                }
                Err(failure) => {
                    tracing::warn!(%failure, "the saved connections reset task failed");
                    Some(crate::ui::error_text::task_failure_message(&failure))
                }
            };
            toasts.add_toast(crate::ui::plain_toast(&reset_failure_text(reason.as_deref())));
        });
    }
}

/// A Safe Mode level to write to the saved connection `id`, and whether
/// the window then connects again to apply it.
#[derive(Debug, Clone, Copy)]
pub(super) struct LevelSave {
    id: Uuid,
    level: SafeModeLevel,
    reopen: bool,
}

/// One result from work that can fail and a task that can die.
fn flatten<T>(
    outcome: Result<Result<T, SavedConnectionError>, tablepro_session::runtime::TaskFailure>,
) -> Result<T, SavedConnectionError> {
    outcome.map_err(SavedConnectionError::from).and_then(|result| result)
}

fn ask_where_to_export(window: &SessionWindow, bytes: Vec<u8>, input: InputSender<SessionWindowInput>) {
    let dialog = gtk::FileDialog::builder()
        .title(crate::i18n::gettext("Export Connections"))
        .modal(true)
        .initial_name("tablepro-connections.json")
        .default_filter(&json_filter())
        .filters(&json_filters())
        .build();
    dialog.save(Some(window), gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else { return };
        glib::spawn_future_local(async move {
            let message = match crate::ui::file_write::replace_file(&file, bytes).await {
                Ok(()) => crate::i18n::gettext("Connections exported."),
                Err(error) => {
                    tracing::warn!(%error, uri = %file.uri(), "could not write the exported connections");
                    crate::i18n::gettext("The connections could not be written to that file.")
                }
            };
            input.deliver(SessionWindowInput::ShowToast(message));
        });
    });
}

/// Why an import changed nothing. Only a problem with the chosen file
/// is the file's fault; the saved list may be unreadable or the disk
/// full.
fn import_failure_message(error: tablepro_storage::StorageError, file: &std::path::Path) -> String {
    match error {
        tablepro_storage::StorageError::DocumentUnavailable(problem) if problem.path == file => {
            if problem.is_newer_version() {
                crate::i18n::gettext("That export comes from a newer version of TablePro.")
            } else {
                crate::i18n::gettext("That file is not a TablePro connection export.")
            }
        }
        other => crate::ui::error_text::saved_connection_error_message(&SavedConnectionError::Storage(other)),
    }
}

/// An export holds names, hosts and options, never secrets, so even
/// thousands of connections come to well under this.
const MAX_CONNECTIONS_FILE_BYTES: usize = 8 * 1024 * 1024;

/// The chosen export, whole, or what to tell the user instead.
async fn read_connections_file(file: &gio::File) -> Result<Vec<u8>, String> {
    read_capped_file(file, MAX_CONNECTIONS_FILE_BYTES)
        .await
        .map_err(|error| match error {
            FileReadError::NotRegular => crate::i18n::gettext("Only regular files can be imported."),
            FileReadError::TooLarge => crate::i18n::gettext("That file is too large to be a connection export."),
            FileReadError::Io(error) => {
                tracing::warn!(%error, "could not read the file to import");
                crate::i18n::gettext("That file could not be read.")
            }
        })
}

fn reset_failure_text(reason: Option<&str>) -> String {
    match reason {
        Some(reason) => crate::i18n::gettext_f(
            "The saved connections could not be reset. {reason}",
            &[("reason", reason)],
        ),
        None => crate::i18n::gettext("The saved connections could not be reset."),
    }
}

/// The filter both file dialogs open with. Built fresh each time
/// because a GtkFileFilter belongs to the dialog it is given to.
fn json_filter() -> gtk::FileFilter {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::i18n::gettext("JSON files")));
    filter.add_suffix("json");
    filter.add_mime_type("application/json");
    filter
}

fn json_filters() -> gio::ListStore {
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&json_filter());
    filters
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use secrecy::SecretString;
    use tablepro_core::credentials::{SecretError, SecretKind, SecretVault};
    use tablepro_storage::ConnectionColor;
    use tablepro_test_support::Call;

    use super::*;
    use crate::test_support::{drain_main_context, finish_on_main, respond, wait_until};
    use crate::ui::session_window::tests::{TestWindow, WAIT};

    fn read(path: &std::path::Path) -> Result<Vec<u8>, String> {
        let file = gio::File::for_path(path);
        crate::test_support::finish_on_main(
            Duration::from_secs(10),
            async move { read_connections_file(&file).await },
        )
        .expect("the read to end")
    }

    #[gtk4::test]
    fn an_import_from_a_pipe_is_refused_without_waiting_for_a_writer() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("connections.json");
        let made = std::process::Command::new("mkfifo")
            .arg(&path)
            .status()
            .expect("mkfifo");
        assert!(made.success());

        let refused = read(&path).expect_err("a refusal");

        assert!(refused.contains("regular files"), "{refused}");
    }

    #[gtk4::test]
    fn an_import_past_the_limit_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("connections.json");
        std::fs::write(&path, vec![b' '; MAX_CONNECTIONS_FILE_BYTES + 1]).expect("write");

        let refused = read(&path).expect_err("a refusal");

        assert!(refused.contains("too large"), "{refused}");
    }

    #[test]
    fn only_a_problem_with_the_chosen_file_blames_it() {
        use tablepro_storage::{DocumentProblem, DocumentProblemKind, StorageError};

        let chosen = std::path::Path::new("/home/u/export.json");
        let problem = |path: &str| {
            StorageError::DocumentUnavailable(DocumentProblem::new(path, DocumentProblemKind::MissingVersion))
        };

        assert_eq!(
            import_failure_message(problem("/home/u/export.json"), chosen),
            "That file is not a TablePro connection export."
        );
        let list_unreadable = import_failure_message(problem("/home/u/.local/share/connections.json"), chosen);
        assert!(!list_unreadable.contains("That file"), "{list_unreadable}");
        let disk_full = import_failure_message(
            StorageError::Io {
                path: "/home/u/.local/share/tablepro/connections.json".into(),
                source: std::io::Error::from(std::io::ErrorKind::StorageFull),
            },
            chosen,
        );
        assert_eq!(
            disk_full,
            "Could not write /home/u/.local/share/tablepro/connections.json: the disk is full."
        );
    }

    #[test]
    fn a_failed_reset_says_why_in_the_apps_words() {
        use tablepro_storage::StorageError;

        let read_only = StorageError::Io {
            path: "/home/u/.local/share/tablepro/connections.json".into(),
            source: std::io::Error::from(std::io::ErrorKind::ReadOnlyFilesystem),
        };
        let readable = StorageError::Schema("the saved connections are readable; there is nothing to reset".to_owned());
        let text =
            |error: &StorageError| reset_failure_text(crate::ui::error_text::storage_io_message(error).as_deref());

        assert_eq!(
            text(&read_only),
            "The saved connections could not be reset. Could not write /home/u/.local/share/tablepro/connections.json: the disk is read-only."
        );
        assert_eq!(text(&readable), "The saved connections could not be reset.");
    }

    #[gtk4::test]
    fn an_export_is_read_whole() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("connections.json");
        std::fs::write(&path, br#"{"connections":[]}"#).expect("write");

        assert_eq!(read(&path).as_deref(), Ok(&br#"{"connections":[]}"#[..]));
    }

    fn open_alert(window: &SessionWindow) -> Option<adw::AlertDialog> {
        window
            .dialogs()
            .iter::<glib::Object>()
            .filter_map(|item| item.ok()?.downcast::<adw::AlertDialog>().ok())
            .next()
    }

    fn wait_for_alert(window: &SessionWindow) -> adw::AlertDialog {
        let mut shown = None;
        wait_until(WAIT, || {
            shown = open_alert(window);
            shown.is_some()
        })
        .expect("a dialog");
        shown.expect("the dialog")
    }

    /// The picker lists the test's connection, which names it in the
    /// dialogs.
    fn wait_for_list(window: &SessionWindow) {
        let list = window
            .state()
            .expect("the window's state")
            .services
            .saved_connections
            .clone();
        wait_until(WAIT, || !list.connections().is_empty()).expect("the connection list");
    }

    fn listed(test: &TestWindow, id: Uuid) -> bool {
        test.services
            .storage
            .connections()
            .load_blocking()
            .expect("the list")
            .iter()
            .any(|saved| saved.id == id)
    }

    fn store_password(test: &TestWindow) {
        let (vault, id) = (test.vault.clone(), test.saved.id);
        finish_on_main(WAIT, async move {
            vault
                .store(id, SecretKind::DatabasePassword, &SecretString::from("s3cret"), "label")
                .await
        })
        .expect("the store to end")
        .expect("the password stored");
    }

    #[gtk4::test]
    fn open_connection_shows_is_open_dialog() {
        let test = TestWindow::connected("DeleteOpen");
        let other = test
            .app
            .open_window(crate::application::WindowLaunch::Picker)
            .and_then(|window| window.downcast::<SessionWindow>().ok())
            .expect("a second window");
        wait_until(WAIT, || other.page_name() == "picker").expect("the second window's picker");
        wait_for_list(&other);
        test.window.set_visible(false);

        other.send(SessionWindowInput::DeleteConnection(test.saved.id));
        let alert = wait_for_alert(&other);
        assert_eq!(alert.heading().as_deref(), Some("“Fake” Is Open"));
        respond(&alert, delete_connection_dialog::SHOW);
        wait_until(WAIT, || test.window.is_visible()).expect("the owner to come forward");

        assert!(listed(&test, test.saved.id), "an open connection was deleted");
        assert!(
            !test.vault.calls().contains(&Call::DeleteConnection(test.saved.id)),
            "an open connection's secrets were deleted"
        );
    }

    #[gtk4::test]
    fn a_confirmed_delete_removes_the_entry_and_its_secrets() {
        let test = TestWindow::picker("DeleteConfirmed");
        wait_for_list(&test.window);
        store_password(&test);

        test.window.send(SessionWindowInput::DeleteConnection(test.saved.id));
        let alert = wait_for_alert(&test.window);
        assert_eq!(alert.heading().as_deref(), Some("Delete “Fake”?"));
        let switch = crate::test_support::descendants(&alert.extra_child().expect("the dialog's rows"))
            .into_iter()
            .find_map(|widget| widget.downcast::<adw::SwitchRow>().ok())
            .expect("the history switch");
        assert!(!switch.is_active(), "the history would go by default");
        respond(&alert, delete_connection_dialog::DELETE);

        wait_until(WAIT, || !listed(&test, test.saved.id)).expect("the entry to go");
        assert!(test.vault.is_empty(), "the secrets outlived the entry");
        wait_until(WAIT, || test.services.saved_connections.connections().is_empty())
            .expect("the picker to drop the entry");
    }

    #[gtk4::test]
    fn retry_toast_reruns_deletion() {
        let test = TestWindow::picker("DeleteRetry");
        wait_for_list(&test.window);
        store_password(&test);
        test.vault.fail_delete_connection(SecretError::Locked);

        test.window.send(SessionWindowInput::DeleteConnection(test.saved.id));
        respond(&wait_for_alert(&test.window), delete_connection_dialog::DELETE);
        let mut retry = None;
        wait_until(WAIT, || {
            retry = test
                .window
                .imp()
                .toasts
                .borrow()
                .iter()
                .find(|toast| toast.button_label().is_some())
                .cloned();
            retry.is_some()
        })
        .expect("a toast offering Retry");
        assert!(listed(&test, test.saved.id), "the entry went while its secrets stayed");
        assert!(!test.vault.is_empty());
        test.vault.clear_failures();

        retry.expect("the toast").emit_by_name::<()>("button-clicked", &[]);

        wait_until(WAIT, || !listed(&test, test.saved.id)).expect("the retried delete");
        assert!(test.vault.is_empty());
        assert!(open_alert(&test.window).is_none(), "Retry asked again");
    }

    #[gtk4::test]
    fn connection_list_writes_hold_the_process_until_they_land() {
        let test = TestWindow::picker("ListWritesHeld");
        wait_for_list(&test.window);
        wait_until(WAIT, || test.hold.live() == 0).expect("nothing else to hold the process");
        let id = test.saved.id;
        let stored = || test.services.storage.connections().load_blocking().expect("the list");

        test.window.on_set_connection_color(id, Some(ConnectionColor::Red));
        assert_eq!(test.hold.live(), 1, "the colour was written without a hold");
        wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");
        assert_eq!(
            stored()[0].color,
            Some(ConnectionColor::Red),
            "the hold ended before the write"
        );

        test.window.on_duplicate_connection(test.saved.id);
        assert_eq!(test.hold.live(), 1, "the copy was written without a hold");
        wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");
        let copy = stored()
            .iter()
            .find(|saved| saved.id != id)
            .cloned()
            .expect("the copy, written before the hold ended");

        test.window.on_confirm_delete(copy.id, DeletionOptions::default());
        assert_eq!(test.hold.live(), 1, "the delete ran without a hold");
        wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");
        assert!(!listed(&test, copy.id), "the hold ended before the delete");
    }

    #[gtk4::test]
    fn a_refused_copy_says_what_failed_and_why() {
        let test = TestWindow::picker("CopyRefused");
        wait_for_list(&test.window);
        store_password(&test);
        test.vault.fail_store(SecretKind::DatabasePassword, SecretError::Locked);

        let toasts = || -> Vec<String> {
            test.window
                .imp()
                .toasts
                .borrow()
                .iter()
                .filter_map(|toast| toast.title().map(|title| title.to_string()))
                .collect()
        };

        test.window.on_duplicate_connection(test.saved.id);
        wait_until(WAIT, || !toasts().is_empty()).expect("the refusal");

        assert_eq!(
            toasts(),
            ["The connection could not be duplicated. The keyring is locked. Unlock it and try again."]
        );
    }

    #[gtk4::test]
    fn a_delete_keeps_the_connection_from_opening_until_it_ends() {
        let test = TestWindow::picker("DeleteClaims");
        wait_for_list(&test.window);
        let key = test.key();

        test.window.on_confirm_delete(test.saved.id, DeletionOptions::default());

        assert!(
            test.services
                .sessions
                .claim(key.clone(), test.window.id() + 100)
                .is_err(),
            "a connect could claim the entry being deleted"
        );
        wait_until(WAIT, || test.hold.live() == 0).expect("the delete to end");
        assert!(!listed(&test, test.saved.id));
        assert_eq!(
            test.services.sessions.window_for(&key),
            None,
            "the key stayed claimed after the delete"
        );
    }

    #[gtk4::test]
    fn a_deleted_connection_still_listed_elsewhere_does_not_open() {
        let test = TestWindow::picker("DeletedRow");
        wait_for_list(&test.window);
        test.window.on_confirm_delete(test.saved.id, DeletionOptions::default());
        wait_until(WAIT, || test.hold.live() == 0).expect("the delete to end");

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        wait_until(WAIT, || {
            test.window
                .imp()
                .toasts
                .borrow()
                .iter()
                .any(|toast| toast.title().as_deref() == Some("The connection was deleted."))
        })
        .expect("the user to be told");

        assert_eq!(test.window.page_name(), "picker");
        assert!(
            test.connector.calls().is_empty(),
            "a deleted connection was connected to"
        );
        assert_eq!(test.services.sessions.window_for(&test.key()), None);
    }

    #[gtk4::test]
    fn reset_holds_the_process_until_the_list_is_moved_aside() {
        let test = TestWindow::with_script(
            "ResetHeld",
            crate::ui::session_window::tests::Script {
                unreadable_list: true,
                ..Default::default()
            },
        );
        let state = || test.services.storage.connections().snapshot().state;
        wait_until(WAIT, || matches!(state(), ConnectionListState::Unavailable(_))).expect("the unreadable list");
        wait_until(WAIT, || test.hold.live() == 0).expect("nothing else to hold the process");

        test.window.reset_connection_list();
        assert_eq!(test.hold.live(), 1, "the reset ran without a hold");
        wait_until(WAIT, || test.hold.live() == 0).expect("the hold to end");

        assert!(
            matches!(state(), ConnectionListState::Ready(_)),
            "the hold ended before the list was moved aside"
        );
    }

    #[gtk4::test]
    fn reset_closes_its_alert_once() {
        let test = TestWindow::with_script(
            "ResetClosedOnce",
            crate::ui::session_window::tests::Script {
                unreadable_list: true,
                ..Default::default()
            },
        );
        let state = || test.services.storage.connections().snapshot().state;
        wait_until(WAIT, || matches!(state(), ConnectionListState::Unavailable(_))).expect("the unreadable list");
        test.window.on_reset_connection_list();
        wait_for_alert(&test.window);

        // With animations off, closing the alert after its click already
        // closed it logs a critical, which this makes abort the test.
        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
        let answered = crate::workspace::answer(&test.window, "reset");
        crate::test_support::drain_main_context();
        glib::log_set_always_fatal(previous);

        assert!(answered, "the alert has no Reset button");
        assert!(open_alert(&test.window).is_none(), "the alert stayed open");
        wait_until(WAIT, || matches!(state(), ConnectionListState::Ready(_))).expect("the list to be moved aside");
    }

    #[gtk4::test]
    fn an_edit_saved_while_the_connection_is_open_says_when_it_applies() {
        let test = TestWindow::connected("EditWhileOpen");
        let other = test
            .app
            .open_window(crate::application::WindowLaunch::Picker)
            .and_then(|window| window.downcast::<SessionWindow>().ok())
            .expect("a second window");
        wait_until(WAIT, || other.page_name() == "picker").expect("the second window's picker");

        other.send(SessionWindowInput::ConnectionSaved(test.saved.id));

        wait_until(WAIT, || {
            other
                .imp()
                .toasts
                .borrow()
                .iter()
                .any(|toast| toast.title().as_deref() == Some("Changes apply the next time you connect"))
        })
        .expect("the user to be told");
        assert_eq!(
            test.window.page_name(),
            "workspace",
            "the edit touched the open session"
        );
        assert_eq!(test.connector.calls().len(), 1, "the edit reconnected the session");
    }

    #[gtk4::test]
    fn an_edit_of_a_closed_connection_says_nothing() {
        let test = TestWindow::picker("EditWhileClosed");

        test.window.send(SessionWindowInput::ConnectionSaved(test.saved.id));
        drain_main_context();

        assert!(test.window.imp().toasts.borrow().is_empty());
        assert_eq!(test.window.page_name(), "picker");
    }
}
