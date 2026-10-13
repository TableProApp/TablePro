use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{ComponentController, ComponentSender, adw, gtk};

use tablepro_core::meta::ObjectInfo;
use tablepro_session::connect::AttemptGeneration;
use tablepro_session::runtime::{ProcessHold, WatchForwarder};
use tablepro_session::{
    ClaimError, ConnectAttempts, ConnectError, CredentialSource, MonitorSignal, PendingSession, Session, SessionClaim,
    SessionHealth, SessionKey,
};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use tablepro_session::RequestTarget;
use tablepro_session::connect::StoreConnectionWrites;

use crate::services::active_session::ActiveSession;
use crate::ui::connect_dialog::{ConnectDialog, ConnectDialogInit, ConnectPrefill, ConnectSubmission, FormField};
use crate::ui::error_text::TlsRemedy;
use crate::ui::ssh_inputs::SshEnvironment;

use super::connect_flow::{self, SubmitError};
use super::teardown_guard::Teardown;
use super::{App, AppMsg, qualified_label};

/// What a failed connect can be retried from: the connection as it was
/// submitted, and the setting that would fix it.
#[derive(Debug)]
pub(crate) struct ConnectRetry {
    pub prefill: ConnectPrefill,
    pub remedy: Option<TlsRemedy>,
}

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

/// A connect that worked, waiting for the window to adopt it.
pub(crate) struct ReadySession {
    pub key: SessionKey,
    pub pending: PendingSession,
    /// What a reconnect reads its secrets from.
    pub credentials: Arc<dyn CredentialSource>,
    /// Secrets the keyring refused to keep, one sentence each.
    pub warnings: Vec<String>,
    /// The attempt it came from, when the window started it, so a late
    /// result loses to a newer attempt.
    pub generation: Option<AttemptGeneration>,
}

impl std::fmt::Debug for ReadySession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReadySession")
            .field("key", &self.key)
            .field("pending", &self.pending)
            .field("generation", &self.generation)
            .finish_non_exhaustive()
    }
}

/// What ties the adopted session to this window. Dropping it releases
/// the registry key and stops the watchers that feed the banner and the
/// sidebar.
pub(crate) struct SessionLinks {
    key: SessionKey,
    _claim: SessionClaim,
    _health: WatchForwarder,
    _catalog: WatchForwarder,
}

fn spawn_local(future: futures::future::LocalBoxFuture<'static, ()>) {
    glib::spawn_future_local(future);
}

impl App {
    pub(super) fn on_open_connect(&mut self, sender: ComponentSender<Self>) {
        self.present_connect_dialog(None, None, sender);
    }

    /// Show the connect dialog, filled from `prefill` when a connect
    /// from it failed, with the focus on `focus`.
    fn present_connect_dialog(
        &mut self,
        prefill: Option<ConnectPrefill>,
        focus: Option<FormField>,
        sender: ComponentSender<Self>,
    ) {
        let dialog = ConnectDialog::new(ConnectDialogInit {
            drivers: self.context.drivers.clone(),
            connector: self.context.connector.clone(),
            interaction: self.context.attended(),
            tasks: self.tasks.clone(),
            saved_connections: Arc::from(self.saved_connections.clone()),
            remembered_driver: self.settings.connect_dialog_driver(),
            ssh_environment: SshEnvironment::detect(),
            prefill,
        });
        let submitted = sender.clone();
        dialog.connect_submitted(move |_, submission| {
            submitted.input(AppMsg::ConnectSubmitted(Box::new(submission)));
        });
        let closed = sender;
        dialog.connect_closed(move |_| closed.input(AppMsg::DialogClosed));
        dialog.present(Some(&self.window));
        if let Some(field) = focus {
            dialog.reveal_field(field);
        }
        self.dialog = Some(dialog);
    }

    /// Connect to what the dialog was filled in with, then save it. The
    /// entry is only written once the connect works, so a typo never
    /// lands in the connection list.
    pub(super) fn on_connect_submission(&mut self, submission: ConnectSubmission, sender: ComponentSender<Self>) {
        if self.context.active.is_connected() {
            let proceed = AppMsg::ConnectSubmissionConfirmed(Box::new(submission));
            self.confirm_teardown(Teardown::Switch, proceed, sender);
            return;
        }
        self.connect_submission(submission, sender);
    }

    pub(super) fn connect_submission(&mut self, submission: ConnectSubmission, sender: ComponentSender<Self>) {
        let ConnectSubmission { request, pending_save } = submission;
        self.set_loading_page(
            &crate::i18n::gettext("Connecting…"),
            &crate::i18n::gettext_f("Opening {name}", &[("name", &request.metadata.name)]),
            &sender,
        );
        let ticket = self.connect_attempts.begin();
        let generation = ticket.generation();
        let cancel = ticket.cancel().clone();
        let retry = ConnectRetry {
            prefill: ConnectPrefill {
                connection: pending_save.connection.clone(),
                password: typed_password(&request.target),
            },
            remedy: None,
        };
        let connector = self.context.connector.clone();
        let interaction = self.context.attended();
        let secrets = self.context.secrets.clone();
        let writes = StoreConnectionWrites::new(self.storage.connections().clone(), self.tasks.clone());
        let connecting = async move {
            connect_flow::connect_then_save(
                &*connector,
                request,
                interaction,
                cancel,
                &*secrets,
                &writes,
                pending_save,
            )
            .await
        };
        let context = self.context.clone();
        let settings = self.settings.clone();
        crate::runtime::spawn_and_deliver(&self.tasks, connecting, move |outcome| {
            let failed = |message: String, retry: ConnectRetry| AppMsg::ConnectFailed {
                generation,
                message: Some(message),
                edit: Some(Box::new(retry)),
            };
            let message = match outcome {
                Ok(Ok((pending, report))) => {
                    // The dialog opens on this driver next time.
                    if let Err(error) = settings.set_connect_dialog_driver(&report.saved.driver_id) {
                        tracing::warn!(%error, "could not remember the connect dialog driver");
                    }
                    AppMsg::SessionReady(Box::new(ReadySession {
                        key: SessionKey::Saved(report.saved.id),
                        credentials: Arc::new(context.keyring_credentials(&report.saved)),
                        pending,
                        // A keyring refusal must not be silent: the
                        // connection opened, but the password will be
                        // asked for next time.
                        warnings: report
                            .secret_failures
                            .iter()
                            .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                            .collect(),
                        generation: Some(generation),
                    }))
                }
                Ok(Err(SubmitError::Connect(ConnectError::Cancelled))) => AppMsg::ConnectFailed {
                    generation,
                    message: None,
                    edit: None,
                },
                Ok(Err(SubmitError::Connect(error))) => failed(
                    crate::ui::error_text::connect_error_message(&error),
                    ConnectRetry {
                        remedy: crate::ui::error_text::connect_remedy(&error),
                        ..retry
                    },
                ),
                Ok(Err(SubmitError::Save(error))) => failed(
                    crate::i18n::gettext_f(
                        "The connection could not be saved: {error}",
                        &[("error", &error.to_string())],
                    ),
                    retry,
                ),
                Err(failure) => failed(crate::ui::error_text::task_failure_message(&failure), retry),
            };
            sender.input(message);
        });
    }

    pub(super) fn on_cancel_connect(&mut self) {
        stop_connecting(&self.connect_attempts);
        self.dismiss_loading_page();
    }

    pub(super) fn on_edit_connection(&mut self, retry: ConnectRetry, sender: ComponentSender<Self>) {
        let focus = retry.remedy.map(crate::ui::connect_dialog::remedy_field);
        self.present_connect_dialog(Some(retry.prefill), focus, sender);
    }

    /// Adopt a session that connected: claim its key, start it, and
    /// build the workspace on its catalog.
    pub(super) fn on_session_ready(&mut self, ready: ReadySession, sender: ComponentSender<Self>) {
        let ReadySession {
            key,
            pending,
            credentials,
            warnings,
            generation,
        } = ready;
        if generation.is_some_and(|generation| !self.connect_attempts.accepts(generation)) {
            self.discard_pending(pending);
            return;
        }
        self.dismiss_loading_page();
        if self.session_links.as_ref().is_some_and(|links| links.key == key) {
            self.discard_pending(pending);
            self.show_toast(&crate::i18n::gettext("This connection is already open."));
            return;
        }
        // One window shows one database, so the one open now goes first.
        if self.context.active.is_connected() {
            self.release_session(sender.clone());
        }
        let claim = match self.context.sessions.claim(key.clone(), self.window.id()) {
            Ok(claim) => claim,
            Err(ClaimError::AlreadyOpen { .. }) => {
                self.discard_pending(pending);
                self.show_toast(&crate::i18n::gettext(
                    "This connection is already open in another window.",
                ));
                return;
            }
        };
        let driver_id = pending.metadata().driver_id.clone();
        let session = Session::start(pending, self.context.session_deps(credentials));
        claim.attach(&session);
        self.context.active.replace(session.clone());

        let catalog = session.catalog();
        let first = catalog.borrow().clone();
        let health_sender = sender.clone();
        let catalog_sender = sender.clone();
        let mut shown = first.generation;
        self.session_links = Some(SessionLinks {
            key,
            _claim: claim,
            _health: WatchForwarder::new(
                session.health(),
                move |health| health_sender.input(AppMsg::HealthChanged(health)),
                spawn_local,
            ),
            // A reconnect reads the catalog again; the first one is
            // already on screen.
            _catalog: WatchForwarder::new(
                catalog,
                move |snapshot: tablepro_session::CatalogSnapshot| {
                    if snapshot.generation != shown {
                        shown = snapshot.generation;
                        catalog_sender.input(AppMsg::CatalogChanged(snapshot.objects.to_vec()));
                    }
                },
                spawn_local,
            ),
        });
        for warning in warnings {
            self.show_toast(&warning);
        }
        self.dialog = None;
        self.on_connected(first.objects.to_vec(), driver_id, sender);
    }

    /// A connect failed. A cancelled one returns to the list without an
    /// error: the user is the one who stopped it. Otherwise the alert
    /// offers to edit what was connected to, starting at the setting
    /// that fixes a TLS failure when there is one.
    pub(super) fn on_connect_failed(
        &mut self,
        generation: AttemptGeneration,
        message: Option<String>,
        edit: Option<Box<ConnectRetry>>,
        sender: ComponentSender<Self>,
    ) {
        if !self.connect_attempts.accepts(generation) {
            return;
        }
        self.dismiss_loading_page();
        let Some(message) = message else {
            return;
        };
        tracing::warn!(error = %message, "connect failed");
        let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Could Not Connect")), Some(&message));
        dialog.add_response("close", &crate::i18n::gettext("Close"));
        dialog.set_close_response("close");
        dialog.set_default_response(Some("close"));
        if let Some(retry) = edit {
            let label = retry
                .remedy
                .map_or_else(|| crate::i18n::gettext("Edit Connection…"), |remedy| remedy.label());
            dialog.add_response("edit", &label);
            dialog.set_default_response(Some("edit"));
            let retry = std::cell::RefCell::new(Some(retry));
            dialog.connect_response(Some("edit"), move |_, _| {
                if let Some(retry) = retry.borrow_mut().take() {
                    sender.input(AppMsg::EditConnection(retry));
                }
            });
        }
        dialog.present(Some(&self.window));
    }

    /// Throw away a connection nobody adopted, closing it under the
    /// close deadline while the process stays alive for it.
    fn discard_pending(&self, pending: PendingSession) {
        let hold = self.context.hold.acquire();
        let closing = self.context.tasks.spawn_task(pending.discard());
        glib::spawn_future_local(async move {
            if let Ok(report) = closing.await {
                tracing::debug!(?report, "closed a connection that was not adopted");
            }
            drop(hold);
        });
    }

    fn on_connected(&mut self, objects: Vec<ObjectInfo>, driver_id: String, sender: ComponentSender<Self>) {
        self.dismiss_loading_page();
        self.dialog = None;
        self.connected = true;
        self.current_driver_id = Some(driver_id.clone());
        self.read_only = self.context.active.read_only();
        self.read_only_badge.set_visible(self.read_only);
        self.reconnect_banner.set_revealed(false);
        self.split_view.set_show_sidebar(true);
        self.disconnect_action.set_enabled(true);
        self.table_search.set_text("");
        // Build the unified workspace tab tree (Browse + Editor share one
        // strip). Empty state shows "Select a table" until the user opens
        // a tab via sidebar click or Ctrl+T.
        self.ensure_workspace_root(sender.clone());
        self.content_holder.set_content(Some(&self.workspace_outer_stack));
        let browsable = browsable(objects);
        self.table_names = browsable.iter().map(|object| object.name.clone()).collect();
        tracing::info!(driver = %driver_id, table_count = browsable.len(), "workspace ready");
        self.repopulate_sidebar(&browsable);
        self.rebuild_schema_buffer();
        self.refresh_window_title();
        // Restore tabs (browse + editor) persisted from the prior session
        // for this connection.
        if let Some(connection_id) = self.context.active.metadata().map(|metadata| metadata.id) {
            self.restore_workspace_tabs(connection_id, sender.clone());
            // Stamp `last_opened_at = now()` then reload connections so
            // the popover + welcome view re-sort with the fresh
            // timestamp. Sequencing matters: ReloadConnections reads
            // the JSON; firing it before the touch lands would render
            // the previous ordering until the next reload.
            let sender_for_touch = sender.clone();
            let connections = self.storage.connections().clone();
            let touching = self
                .tasks
                .spawn_blocking_task(move || connections.touch_last_opened_blocking(connection_id));
            glib::spawn_future_local(async move {
                match touching.await {
                    Ok(Err(error)) => tracing::warn!(%error, "could not stamp the last-opened time"),
                    Err(error) => tracing::warn!(%error, "the last-opened task failed"),
                    Ok(Ok(())) => {}
                }
                sender_for_touch.input(AppMsg::ReloadConnections);
            });
            return;
        }
        sender.input(AppMsg::ReloadConnections);
    }

    pub(super) fn on_disconnect(&mut self, sender: ComponentSender<Self>) {
        self.confirm_teardown(Teardown::Disconnect, AppMsg::ForceDisconnect, sender);
    }

    pub(super) fn do_disconnect(&mut self, sender: ComponentSender<Self>) {
        self.release_session(sender.clone());
        self.split_view.set_show_sidebar(false);
        self.disconnect_action.set_enabled(false);
        self.refresh_window_title();
        self.show_welcome_page(sender);
        tracing::info!("disconnected");
    }

    /// Close the workspace and shut the session down. The process is
    /// held until the close ends, so quitting right after a disconnect
    /// does not cut the connection off mid-close.
    fn release_session(&mut self, _sender: ComponentSender<Self>) {
        // Persist + tear down workspace tabs before dropping the
        // session (persist needs the active connection id).
        self.teardown_workspace_tabs();
        // Drop reopen-stack entries — they reference tables in the
        // connection we're about to release. Reopening one against a
        // different connection would target a non-existent table.
        self.clear_closed_tabs_stack();
        self.session_links = None;
        close_session(&self.context.active, &*self.context.hold);
        self.reconnect_banner.set_revealed(false);
        self.schema_buffer.set_text(crate::ui::editor::SQL_KEYWORDS);
        self.current_driver_id = None;
        self.read_only = false;
        self.read_only_badge.set_visible(false);
        self.connected = false;
        self.table_search.set_text("");
        self.sidebar_schemas.borrow_mut().clear();
        self.sidebar_factory.guard().clear();
    }

    /// The banner's Retry: the only thing that wakes a parked session.
    pub(super) fn on_retry_connection(&self) {
        if let Some(session) = self.context.active.get() {
            session.signal(MonitorSignal::RetryNow);
        }
    }

    pub(super) fn on_reload_connections(&self, sender: ComponentSender<Self>) {
        let store = self.storage.connections().clone();
        let reading = self.tasks.spawn_blocking_task(move || store.load_blocking());
        glib::spawn_future_local(async move {
            match reading.await {
                Ok(Ok(connections)) => sender.input(AppMsg::ConnectionsLoaded(connections.to_vec())),
                Ok(Err(error)) => {
                    tracing::warn!(%error, "the saved connections could not be read");
                    sender.input(AppMsg::ConnectionListUnavailable);
                }
                Err(failure) => tracing::warn!(%failure, "the connections read task failed"),
            }
        });
    }

    pub(super) fn on_connections_loaded(&mut self, connections: &[SavedConnection], sender: ComponentSender<Self>) {
        self.saved_connections = connections.to_vec();
        // The popover shows the same list as the welcome page, so it
        // sorts the same way and reads the same group headers.
        crate::ui::connection_list::sort(&mut self.saved_connections);
        let groups = crate::ui::connection_list::groups(&self.saved_connections);
        let mut guard = self.connections_factory.guard();
        guard.clear();
        for saved in &self.saved_connections {
            guard.push_back(crate::ui::connection_row::ConnectionRowInit {
                saved: saved.clone(),
                groups: groups.clone(),
            });
        }
        drop(guard);
        crate::ui::connection_list::install_group_headers(
            &self.connections_listbox,
            std::rc::Rc::new(self.saved_connections.clone()),
        );
        let _ = self
            .welcome_view
            .sender()
            .send(crate::ui::welcome_view::WelcomeViewInput::SetConnections(
                self.saved_connections.clone(),
            ));
        if !self.connected {
            self.show_welcome_page(sender);
        }
    }

    pub(super) fn on_delete_connection(&self, id: Uuid, sender: ComponentSender<Self>) {
        // Connection deletion wipes the saved entry and ALL associated
        // keyring credentials (db password, SSH password, SSH passphrase).
        // Irreversible (no Undo can recover keyring entries) so we
        // confirm unconditionally — the previous `confirm_destructive`
        // preference gate let users skip it, but per HIG (and GNOME
        // Files' bookmark-delete behaviour) destructive keyring writes
        // need confirmation regardless of preferences.
        let connection_name = self
            .saved_connections
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.name.clone())
            .unwrap_or_else(|| crate::i18n::gettext("this connection"));
        let title = crate::i18n::gettext_f("Delete {name}?", &[("name", &connection_name)]);
        let body = crate::i18n::gettext(
            "The saved entry, any stored passwords and the queries saved under this connection \
             will be removed. This cannot be undone.",
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("delete", &crate::i18n::gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let sender_for_response = sender;
        let connections_for_response = self.storage.connections().clone();
        let secrets_for_response = self.storage.secrets().clone();
        let column_widths = self.storage.column_widths().clone();
        let filter_settings = self.storage.filter_settings().clone();
        let tasks_for_response = self.tasks.clone();
        let saved_queries_for_response = self.history.store().map(|history| history.saved_queries());
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "delete" {
                return;
            }
            // Nothing can reach these once the entry is gone, so they
            // go with it rather than accumulating in the state files.
            column_widths.forget_connection(id);
            filter_settings.forget_connection(id);
            execute_delete_connection(
                connections_for_response.clone(),
                secrets_for_response.clone(),
                tasks_for_response.clone(),
                saved_queries_for_response.clone(),
                id,
                sender_for_response.clone(),
            );
        });
        dialog.present(Some(&self.window));
    }

    /// Copy a saved connection so a second database on the same server
    /// does not have to be typed out again.
    ///
    /// The copy takes a new id, so it carries its own secrets rather
    /// than sharing the original's: removing either then leaves the
    /// other able to connect.
    pub(super) fn on_duplicate_connection(&self, source: SavedConnection, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        let copy = tablepro_storage::duplicate(&source, &self.saved_connections);
        let name = copy.name.clone();
        let connections = self.storage.connections().clone();
        let secrets = self.storage.secrets().clone();
        let tasks = self.tasks.clone();
        let spawner = self.tasks.clone();
        let sender_clone = sender.clone();
        drop(spawner.spawn_task(async move {
            let copy_id = copy.id;
            let saved = tasks
                .spawn_blocking_task({
                    let connections = connections.clone();
                    move || connections.upsert_blocking(copy)
                })
                .await;
            if let Ok(Err(error)) = saved {
                tracing::warn!(%error, "could not save the duplicated connection");
                sender_clone.input(AppMsg::ShowToast(crate::i18n::gettext(
                    "The connection could not be duplicated.",
                )));
                return;
            }
            // A copy with no password still connects once the
            // user types one, so a keyring that refuses is
            // reported rather than undoing the copy.
            let carried = copy_secrets(secrets.as_ref(), source.id, copy_id, &name).await;
            sender_clone.input(AppMsg::ReloadConnections);
            sender_clone.input(AppMsg::ShowToast(if carried {
                crate::i18n::gettext_f("Duplicated as {name}", &[("name", &name)])
            } else {
                crate::i18n::gettext_f(
                    "Duplicated as {name}. Its password could not be copied, so enter it again.",
                    &[("name", &name)],
                )
            }));
        }));
    }

    /// File a connection under a group, or take it out of the one it
    /// is in. An empty name means no group.
    pub(super) fn on_set_connection_group(&self, id: Uuid, group: Option<String>, sender: ComponentSender<Self>) {
        let group = group.map(|name| name.trim().to_owned()).filter(|name| !name.is_empty());
        let Some(mut saved) = self.saved_connections.iter().find(|saved| saved.id == id).cloned() else {
            return;
        };
        if saved.group == group {
            return;
        }
        saved.group = group;
        self.write_connection(saved, crate::i18n::gettext("The group could not be saved."), sender);
    }

    /// Put a colour on a connection, or take the one it has off.
    ///
    /// The whole entry is rewritten because that is what the store
    /// takes, and it comes from the list the app already holds rather
    /// than from a re-read: the row that asked is showing that entry.
    pub(super) fn on_set_connection_color(
        &self,
        id: Uuid,
        color: Option<tablepro_storage::ConnectionColor>,
        sender: ComponentSender<Self>,
    ) {
        let Some(mut saved) = self.saved_connections.iter().find(|saved| saved.id == id).cloned() else {
            return;
        };
        if saved.color == color {
            return;
        }
        saved.color = color;
        self.write_connection(saved, crate::i18n::gettext("The colour could not be saved."), sender);
    }

    /// Write one connection back and reload the list from disk, so both
    /// connection lists redraw from what was actually saved.
    fn write_connection(&self, saved: SavedConnection, failure: String, sender: ComponentSender<Self>) {
        let connections = self.storage.connections().clone();
        let tasks = self.tasks.clone();
        let spawner = self.tasks.clone();
        let sender_clone = sender.clone();
        drop(spawner.spawn_task(async move {
            let written = tasks
                .spawn_blocking_task(move || connections.upsert_blocking(saved))
                .await;
            if let Ok(Err(error)) = written {
                tracing::warn!(%error, "could not save the connection");
                sender_clone.input(AppMsg::ShowToast(failure));
            }
            sender_clone.input(AppMsg::ReloadConnections);
        }));
    }

    /// Write the connection list to a file the user picks.
    ///
    /// The file carries no passwords, and the dialog's name says what
    /// it does carry, because it is going somewhere the keyring does
    /// not protect.
    pub(super) fn on_export_connections(&self, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        let connections = self.storage.connections().clone();
        let bytes = match connections.export_blocking() {
            Ok(bytes) => bytes,
            Err(error) => {
                tracing::warn!(%error, "could not read the connections to export");
                self.show_toast(&crate::i18n::gettext("The connections could not be read."));
                return;
            }
        };

        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Export Connections"))
            .modal(true)
            .initial_name("tablepro-connections.json")
            .default_filter(&json_filter())
            .filters(&json_filters())
            .build();
        let input = sender.input_sender().clone();
        dialog.save(Some(&self.window), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let Some(path) = file.path() else { return };
            let message = match std::fs::write(&path, &bytes) {
                Ok(()) => crate::i18n::gettext("Connections exported."),
                Err(error) => {
                    tracing::warn!(%error, path = %path.display(), "could not write the exported connections");
                    crate::i18n::gettext("The connections could not be written to that file.")
                }
            };
            let _ = input.send(AppMsg::ShowToast(message));
        });
    }

    /// Ask for an exported file and read it off the GTK thread.
    pub(super) fn on_import_connections(&self, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Import Connections"))
            .modal(true)
            .default_filter(&json_filter())
            .filters(&json_filters())
            .build();
        let input = sender.input_sender().clone();
        dialog.open(Some(&self.window), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let input = input.clone();
            glib::spawn_future_local(async move {
                let path = file.path().unwrap_or_default();
                match file.load_contents_future().await {
                    Ok((bytes, _etag)) => {
                        let _ = input.send(AppMsg::ConnectionsFileRead {
                            path,
                            bytes: bytes.to_vec(),
                        });
                    }
                    Err(error) => {
                        tracing::warn!(%error, path = %path.display(), "could not read the file to import");
                        let _ = input.send(AppMsg::ShowToast(crate::i18n::gettext("That file could not be read.")));
                    }
                }
            });
        });
    }

    pub(super) fn on_connections_file_read(
        &self,
        path: std::path::PathBuf,
        bytes: Vec<u8>,
        sender: ComponentSender<Self>,
    ) {
        let connections = self.storage.connections().clone();
        let tasks = self.tasks.clone();
        let spawner = self.tasks.clone();
        let sender_clone = sender.clone();
        drop(spawner.spawn_task(async move {
            let imported = tasks
                .spawn_blocking_task(move || connections.import_blocking(&path, &bytes))
                .await;
            let message = match imported {
                Ok(Ok(report)) if report.total() == 0 => crate::i18n::gettext("That file has no connections in it."),
                Ok(Ok(report)) => crate::i18n::ngettext_f(
                    "Imported {n} connection.",
                    "Imported {n} connections.",
                    report.total() as u32,
                    &[("n", &report.total().to_string())],
                ),
                Ok(Err(error)) => {
                    tracing::warn!(%error, "could not import the connections");
                    crate::i18n::gettext("That file is not a TablePro connection export.")
                }
                Err(error) => {
                    tracing::warn!(%error, "the import task did not finish");
                    crate::i18n::gettext("The connections could not be imported.")
                }
            };
            sender_clone.input(AppMsg::ReloadConnections);
            sender_clone.input(AppMsg::ShowToast(message));
        }));
    }

    pub(super) fn on_open_saved(&mut self, saved: SavedConnection, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        let key = SessionKey::Saved(saved.id);
        if self.session_links.as_ref().is_some_and(|links| links.key == key) {
            self.show_toast(&crate::i18n::gettext("This connection is already open."));
            return;
        }
        if self.context.active.is_connected() {
            self.confirm_teardown(Teardown::Switch, AppMsg::OpenSavedConfirmed(saved), sender);
            return;
        }
        self.connect_saved(saved, sender);
    }

    pub(super) fn connect_saved(&mut self, saved: SavedConnection, sender: ComponentSender<Self>) {
        let key = SessionKey::Saved(saved.id);
        self.set_loading_page(
            &crate::i18n::gettext("Connecting…"),
            &crate::i18n::gettext_f("Opening {name}", &[("name", &saved.name)]),
            &sender,
        );
        let ticket = self.connect_attempts.begin();
        let generation = ticket.generation();
        let cancel = ticket.cancel().clone();
        let drivers = self.context.drivers.clone();
        let connector = self.context.connector.clone();
        let interaction = self.context.attended();
        let credentials = self.context.keyring_credentials(&saved);
        let source: Arc<dyn CredentialSource> = Arc::new(credentials.clone());
        let retry = ConnectRetry {
            prefill: ConnectPrefill {
                connection: saved.clone(),
                password: None,
            },
            remedy: None,
        };
        // Reading the keyring, asking for what it lacks and connecting
        // all happen off the GTK thread; only the outcome comes back.
        let connecting = async move {
            connect_flow::connect_saved(&saved, &drivers, &credentials, &*connector, interaction, cancel).await
        };
        crate::runtime::spawn_and_deliver(&self.tasks, connecting, move |outcome| match outcome {
            Ok(Ok((pending, refused))) => sender.input(AppMsg::SessionReady(Box::new(ReadySession {
                key,
                pending,
                credentials: source,
                warnings: refused
                    .iter()
                    .map(|(_, error)| crate::services::secret_save_report::not_saved_message(error))
                    .collect(),
                generation: Some(generation),
            }))),
            Ok(Err(ConnectError::Cancelled)) => sender.input(AppMsg::ConnectFailed {
                generation,
                message: None,
                edit: None,
            }),
            Ok(Err(error)) => sender.input(AppMsg::ConnectFailed {
                generation,
                message: Some(crate::ui::error_text::connect_error_message(&error)),
                edit: Some(Box::new(ConnectRetry {
                    remedy: crate::ui::error_text::connect_remedy(&error),
                    ..retry
                })),
            }),
            Err(failure) => sender.input(AppMsg::ConnectFailed {
                generation,
                message: Some(crate::ui::error_text::task_failure_message(&failure)),
                edit: Some(Box::new(retry)),
            }),
        });
    }

    /// Only what the grid can page through goes in the sidebar.
    pub(super) fn repopulate_sidebar(&mut self, objects: &[ObjectInfo]) {
        let objects = browsable(objects.to_vec());
        {
            let mut schemas = self.sidebar_schemas.borrow_mut();
            schemas.clear();
            schemas.extend(objects.iter().map(|object| object.schema.clone()));
        }
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for object in objects {
            guard.push_back(object);
        }
        drop(guard);
        self.sidebar_factory.widget().invalidate_headers();
    }

    /// Surfaces session health via `adw::Banner` only when degraded:
    /// GNOME apps reserve banners for abnormal, user-actionable states.
    pub(super) fn refresh_health_banner(&self, health: &SessionHealth) {
        match health_banner_text(health) {
            Some(title) => {
                self.reconnect_banner.set_title(&title);
                self.reconnect_banner.set_revealed(true);
            }
            None => self.reconnect_banner.set_revealed(false),
        }
    }

    pub(super) fn refresh_window_title(&self) {
        // Subtitle: "<connection> · <driver>" when connected, empty
        // otherwise. The active table goes in the tab title (where it
        // already lives) — duplicating it in the WindowTitle subtitle
        // both overruns the slot's intended ~7-word capacity and
        // pretends the subtitle is the canonical "where am I?" widget
        // when the tab strip already serves that role. Matches GNOME
        // Builder (subtitle = branch name only) and Text Editor
        // (subtitle = filename only) — short, single-purpose.
        let metadata = self.context.active.metadata();
        let connection_name = metadata.as_ref().map(|m| m.name.as_str());
        let active = self.selected_browse_slot_table();
        let table_pair = active.as_ref().map(|(s, t)| (s.as_deref(), t.as_str()));
        let (mut os_title, subtitle) = match (connection_name, &self.current_driver_id, table_pair) {
            (Some(name), Some(driver), Some((schema, table))) => {
                let label = qualified_label(schema, table);
                (format!("{label} · {name} — TablePro"), format!("{name} · {driver}"))
            }
            (Some(name), Some(driver), None) => (format!("{name} — TablePro"), format!("{name} · {driver}")),
            (None, Some(driver), _) => (format!("{driver} — TablePro"), driver.clone()),
            _ => ("TablePro".to_string(), String::new()),
        };
        // GNOME Text Editor convention: prefix the OS-level window
        // title with "• " when any open document has unsaved changes,
        // so the dirty state is visible from the Activities overview /
        // Alt-Tab without needing the tab to be focused.
        if !self.dirty_tabs().is_empty() {
            os_title = format!("• {os_title}");
        }
        self.window.set_title(Some(&os_title));
        self.window_title.set_subtitle(&subtitle);

        // Sidebar header acts as a breadcrumb: the title shows the
        // active connection name when connected, falling back to the
        // generic "Tables" label on the welcome screen. Subtitle stays
        // empty — the driver / host already lives in the main header.
        match connection_name {
            Some(name) => {
                self.sidebar_title.set_title(name);
            }
            None => {
                self.sidebar_title.set_title(&crate::i18n::gettext("Tables"));
            }
        }
    }
}

/// Supersede the connect in flight, not only cancel it: a driver
/// blocked in a socket call can still connect afterwards, and that late
/// session must not be adopted.
fn stop_connecting(attempts: &ConnectAttempts) {
    drop(attempts.begin());
    attempts.cancel();
}

/// Shut the window's session down and close its connection under the
/// close deadline. The process is held until the close ends, so the
/// server sees the connection closed rather than cut off.
fn close_session(active: &ActiveSession, hold: &dyn ProcessHold) {
    let Some(session) = active.take() else {
        return;
    };
    let hold = hold.acquire();
    let closing = session.begin_shutdown();
    glib::spawn_future_local(async move {
        match closing.await {
            Ok(report) => tracing::debug!(?report, "the session closed"),
            Err(failure) => tracing::warn!(%failure, "the session close task failed"),
        }
        drop(hold);
    });
}

/// What a closing window still owes its connection: no connect left to
/// land in it, and the session closed rather than dropped.
///
/// The window's close request is where this has to start. relm4 calls
/// a detached root's `shutdown` only after the main loop has returned,
/// when no close can run any more and a hold no longer keeps the
/// process alive.
pub(super) fn close_window_session(active: &ActiveSession, hold: &dyn ProcessHold, attempts: &ConnectAttempts) {
    stop_connecting(attempts);
    close_session(active, hold);
}

/// Move every secret the original holds onto the copy's own id.
///
/// Returns whether all of them made it: a keyring that is locked or
/// absent is a reason to tell the user, not to refuse the copy.
async fn copy_secrets(
    secrets: &dyn tablepro_core::credentials::SecretVault,
    from: Uuid,
    to: Uuid,
    label: &str,
) -> bool {
    use tablepro_core::credentials::{SecretKind, SecretLookup};

    let mut carried = true;
    for kind in SecretKind::ALL {
        match secrets.load(from, kind).await {
            Ok(SecretLookup::Found(secret)) => {
                if let Err(error) = secrets.store(to, kind, &secret, label).await {
                    tracing::warn!(%error, ?kind, "could not copy a secret onto the duplicate");
                    carried = false;
                }
            }
            // Nothing stored for this kind, so nothing to carry.
            Ok(SecretLookup::NotStored) => {}
            Err(error) => {
                tracing::warn!(%error, ?kind, "could not read a secret to duplicate");
                carried = false;
            }
        }
    }
    carried
}

fn execute_delete_connection(
    connections: tablepro_storage::ConnectionStore,
    secrets: std::sync::Arc<dyn tablepro_core::credentials::SecretVault>,
    tasks: tablepro_session::runtime::Tasks,
    saved_queries: Option<tablepro_storage::SavedQueries>,
    id: Uuid,
    sender: ComponentSender<App>,
) {
    let sender_clone = sender.clone();
    let spawner = tasks.clone();
    drop(spawner.spawn_task(async move {
        // Secrets first: an entry with no secrets is recoverable,
        // a secret with no entry is orphaned in the keyring.
        if let Err(error) = secrets.delete_connection(id).await {
            // Keep the entry: an entry with no secrets can be
            // fixed, a secret with no entry is orphaned.
            tracing::warn!(%error, "could not delete the connection secrets; keeping the entry");
            sender_clone.input(AppMsg::SecretDeleteFailed(id));
            return;
        }
        let removed = tasks.spawn_blocking_task(move || connections.remove_blocking(id)).await;
        if let Ok(Err(error)) = removed {
            tracing::warn!(%error, "could not remove the saved connection");
        }
        // The queries saved here name tables only this database
        // has, so they go with it. A failure leaves them listed
        // under the connection's last name, which the user can
        // still delete one by one.
        if let Some(saved_queries) = saved_queries
            && let Err(error) = saved_queries.delete_for_connection(id).await
        {
            tracing::warn!(%error, "could not remove the connection's saved queries");
        }
        sender_clone.input(AppMsg::ReloadConnections);
    }));
}

impl App {
    /// The list could not be read, so the user is told rather than shown
    /// an empty welcome view that looks like their connections vanished.
    pub(super) fn show_connection_list_banner(&self) {
        let Some(content) =
            crate::ui::connection_list_banner::banner_content(&self.storage.connections().snapshot().state)
        else {
            self.connection_list_banner.set_revealed(false);
            return;
        };
        self.connection_list_banner.set_title(&content.title);
        self.connection_list_banner
            .set_button_label(Some(&content.button_label));
        self.connection_list_banner.set_revealed(true);
    }

    /// The keyring refused, so the entry stays and the user is offered
    /// another go rather than being left with orphaned secrets.
    pub(super) fn on_secret_delete_failed(&self, id: Uuid, sender: ComponentSender<Self>) {
        let toast = adw::Toast::new(&crate::i18n::gettext(
            "The stored passwords could not be deleted, so the connection was kept.",
        ));
        toast.set_button_label(Some(&crate::i18n::gettext("Retry")));
        let retry_sender = sender;
        toast.connect_button_clicked(move |_| {
            retry_sender.input(AppMsg::DeleteConnection(id));
        });
        self.toast_overlay.add_toast(toast);
    }

    pub(super) fn on_reset_connection_list(&self, sender: ComponentSender<Self>) {
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

        let store = self.storage.connections().clone();
        let banner = self.connection_list_banner.clone();
        let toasts = self.toast_overlay.clone();
        let sender_for_reset = sender;
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "reset" {
                return;
            }
            match store.reset_unreadable_blocking(std::time::SystemTime::now()) {
                Ok(moved) => {
                    banner.set_revealed(false);
                    toasts.add_toast(adw::Toast::new(&crate::ui::connection_list_banner::reset_toast_text(
                        &moved,
                    )));
                    sender_for_reset.input(AppMsg::ReloadConnections);
                }
                Err(error) => {
                    tracing::warn!(%error, "could not reset the saved connections");
                    toasts.add_toast(adw::Toast::new(&crate::i18n::gettext_f(
                        "Could not reset the saved connections: {error}",
                        &[("error", &error.to_string())],
                    )));
                }
            }
        });
        dialog.present(Some(&self.window));
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

/// Only what the grid can page through: routines and sequences have no
/// rows to show.
fn browsable(objects: Vec<ObjectInfo>) -> Vec<ObjectInfo> {
    objects
        .into_iter()
        .filter(|object| object.kind.is_browsable())
        .collect()
}

/// The banner's sentence for a session that needs attention, `None`
/// while it is online.
fn health_banner_text(health: &SessionHealth) -> Option<String> {
    match health {
        SessionHealth::Online => None,
        SessionHealth::Reconnecting { attempt } => Some(crate::i18n::gettext_f(
            "Connection lost. Reconnecting (attempt {n}).",
            &[("n", &attempt.to_string())],
        )),
        SessionHealth::Offline => Some(crate::i18n::gettext(
            "The server cannot be reached. TablePro will keep checking.",
        )),
        SessionHealth::Failed { cause } => Some(failed_banner_text(*cause)),
    }
}

fn failed_banner_text(cause: tablepro_session::FailureCause) -> String {
    use tablepro_session::FailureCause;
    match cause {
        FailureCause::Authentication => {
            crate::i18n::gettext("The server refused the login. Retry to enter the password again.")
        }
        FailureCause::Tls => crate::i18n::gettext("The secure connection failed. Check the connection's TLS settings."),
        FailureCause::Configuration => {
            crate::i18n::gettext("The connection settings no longer work. Check them and retry.")
        }
        FailureCause::HostKeyUnknown => crate::i18n::gettext("The SSH server's host key is not trusted yet."),
        FailureCause::HostKeyChanged => crate::i18n::gettext(
            "The SSH server's host key changed. Check with its administrator before connecting again.",
        ),
        FailureCause::HostKeyRevoked => crate::i18n::gettext("The SSH server's host key was revoked."),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::LivenessPolicy;
    use tablepro_core::meta::ObjectKind;
    use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
    use tablepro_session::operation::DefaultDeadlines;
    use tablepro_session::runtime::CountingHold;
    use tablepro_session::{FailureCause, SessionDeps};
    use tablepro_test_support::ConnectionScript;

    use super::*;

    #[gtk4::test]
    fn a_closing_window_closes_its_session_and_stops_its_connect() {
        let runtime = crate::test_support::test_runtime();
        let (pending, connection) = FakeConnector::pending_session(
            FakeConnector::request().expect("a request"),
            ConnectionScript::default(),
        );
        let session = Session::start(
            pending,
            SessionDeps {
                connector: Arc::new(FakeConnector::new([])),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks: runtime.tasks(),
                prompter: None,
            },
        );
        let active = ActiveSession::new();
        active.replace(session.clone());
        let hold = CountingHold::new();
        let attempts = ConnectAttempts::new();
        let connecting = attempts.begin();

        close_window_session(&active, &hold, &attempts);

        assert!(connecting.is_cancelled(), "the connect in flight kept running");
        assert!(
            !attempts.accepts(connecting.generation()),
            "a late connect would still be adopted"
        );
        assert!(!active.is_connected());
        assert_eq!(hold.live(), 1, "nothing kept the process alive for the close");
        crate::test_support::wait_until(Duration::from_secs(5), || hold.live() == 0).expect("the close to end");
        assert!(session.is_shut_down());
        assert!(connection.is_closed(), "the connection was cut off rather than closed");
    }

    fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        }
    }

    #[test]
    fn the_sidebar_lists_only_what_the_grid_can_page() {
        let listed = browsable(vec![
            object("users", ObjectKind::Table),
            object("active_users", ObjectKind::View),
            object("next_id", ObjectKind::Sequence),
            object("refresh", ObjectKind::Function),
        ]);

        let names: Vec<&str> = listed.iter().map(|object| object.name.as_str()).collect();
        assert_eq!(names, ["users", "active_users"]);
    }

    #[test]
    fn the_banner_shows_only_when_the_session_needs_attention() {
        assert_eq!(health_banner_text(&SessionHealth::Online), None);
        let reconnecting = health_banner_text(&SessionHealth::Reconnecting { attempt: 3 }).expect("a banner");
        assert!(reconnecting.contains('3'), "{reconnecting}");
        assert!(health_banner_text(&SessionHealth::Offline).is_some());
    }

    #[test]
    fn each_parked_cause_has_its_own_banner() {
        let causes = [
            FailureCause::Authentication,
            FailureCause::Tls,
            FailureCause::Configuration,
            FailureCause::HostKeyUnknown,
            FailureCause::HostKeyChanged,
            FailureCause::HostKeyRevoked,
        ];

        let texts: std::collections::HashSet<String> = causes
            .into_iter()
            .map(|cause| health_banner_text(&SessionHealth::Failed { cause }).expect("a banner"))
            .collect();

        assert_eq!(texts.len(), causes.len());
    }
}
