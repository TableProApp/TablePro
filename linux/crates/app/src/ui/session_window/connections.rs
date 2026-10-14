//! The saved connections a window's picker lists, and the connect
//! dialog that adds to them.

use std::sync::Arc;

use gtk4 as gtk;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use relm4::ComponentController;

use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::{ConnectSource, PendingSave, RequestTarget};
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::{SessionWindow, SessionWindowInput};
use crate::runtime::{DeliverInput, InputSender};
use crate::ui::connect_dialog::{ConnectDialog, ConnectDialogInit, ConnectPrefill, FormField};
use crate::ui::file_read::{FileReadError, read_capped_file};
use crate::ui::ssh_inputs::SshEnvironment;

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

/// What the connect dialog opens on to edit a connection that failed:
/// the connection as it was submitted, with the password typed for it.
pub(super) fn prefill_for(source: &ConnectSource) -> Option<ConnectPrefill> {
    match source {
        ConnectSource::Saved(saved) => Some(ConnectPrefill {
            connection: (**saved).clone(),
            password: None,
        }),
        ConnectSource::Intent(intent) => intent.pending_save.as_ref().map(|save| ConnectPrefill {
            connection: save.connection.clone(),
            password: typed_password(&intent.request.target),
        }),
        ConnectSource::File(_) => None,
    }
}

impl SessionWindow {
    /// Show the connect dialog over this window, filled from `prefill`
    /// when a connect from it failed, with the focus on `focus`.
    pub(super) fn present_connect_dialog(&self, prefill: Option<ConnectPrefill>, focus: Option<FormField>) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let context = &state.context;
        let dialog = ConnectDialog::new(ConnectDialogInit {
            drivers: context.drivers.clone(),
            connector: context.connector.clone(),
            interaction: context.attended(),
            tasks: state.services.tasks.clone(),
            saved_connections: Arc::from(self.imp().saved_connections.borrow().clone()),
            remembered_driver: state.services.settings.connect_dialog_driver(),
            ssh_environment: SshEnvironment::detect(),
            prefill,
        });
        let submitted = input.clone();
        dialog.connect_submitted(move |_, submission| {
            submitted.deliver(SessionWindowInput::ConnectFromDialog(Box::new(submission)));
        });
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
        drop(state.services.tasks.spawn_task(async move {
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
                        "The connection could not be saved: {error}",
                        &[("error", &error.to_string())],
                    )));
                }
            }
            input.deliver(SessionWindowInput::ReloadConnections);
        }));
    }

    /// Stamp the connection's last-opened time, then read the list again
    /// so the picker sorts by it. The read waits for the stamp, or it
    /// would show the old order until the next one.
    pub(super) fn touch_last_opened(&self, id: Uuid) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let connections = state.services.storage.connections().clone();
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
            input.deliver(SessionWindowInput::ReloadConnections);
        });
    }

    pub(super) fn on_reload_connections(&self) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let store = state.services.storage.connections().clone();
        let reading = state.services.tasks.spawn_blocking_task(move || store.load_blocking());
        glib::spawn_future_local(async move {
            match reading.await {
                Ok(Ok(connections)) => input.deliver(SessionWindowInput::ConnectionsLoaded(connections.to_vec())),
                Ok(Err(error)) => {
                    tracing::warn!(%error, "the saved connections could not be read");
                    input.deliver(SessionWindowInput::ConnectionListUnavailable);
                }
                Err(failure) => tracing::warn!(%failure, "the connections read task failed"),
            }
        });
    }

    pub(super) fn on_connections_loaded(&self, mut connections: Vec<SavedConnection>) {
        crate::ui::connection_list::sort(&mut connections);
        self.imp().saved_connections.replace(connections.clone());
        if let Some(welcome) = self.imp().welcome.borrow().as_ref() {
            welcome
                .sender()
                .deliver(crate::ui::welcome_view::WelcomeViewInput::SetConnections(connections));
        }
    }

    fn saved_connection(&self, id: Uuid) -> Option<SavedConnection> {
        self.imp()
            .saved_connections
            .borrow()
            .iter()
            .find(|saved| saved.id == id)
            .cloned()
    }

    pub(super) fn on_delete_connection(&self, id: Uuid) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        // The delete takes the keyring secrets with it and has no undo,
        // so it asks whatever the preferences say.
        let connection_name = self
            .saved_connection(id)
            .map_or_else(|| crate::i18n::gettext("this connection"), |saved| saved.name);
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

        let storage = state.services.storage.clone();
        let tasks = state.services.tasks.clone();
        let saved_queries = state.services.history().store().map(|history| history.saved_queries());
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "delete" {
                return;
            }
            // Nothing can reach these once the entry is gone, so they
            // go with it rather than accumulating in the state files.
            storage.column_widths().forget_connection(id);
            storage.filter_settings().forget_connection(id);
            execute_delete_connection(
                storage.connections().clone(),
                storage.secrets().clone(),
                tasks.clone(),
                saved_queries.clone(),
                id,
                input.clone(),
            );
        });
        dialog.present(Some(self));
    }

    /// Copy a saved connection so a second database on the same server
    /// does not have to be typed out again.
    ///
    /// The copy takes a new id, so it carries its own secrets rather
    /// than sharing the original's: removing either then leaves the
    /// other able to connect.
    pub(super) fn on_duplicate_connection(&self, source: SavedConnection) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let copy = tablepro_storage::duplicate(&source, &self.imp().saved_connections.borrow());
        let name = copy.name.clone();
        let connections = state.services.storage.connections().clone();
        let secrets = state.services.storage.secrets().clone();
        let tasks = state.services.tasks.clone();
        drop(state.services.tasks.spawn_task(async move {
            let copy_id = copy.id;
            let saved = tasks
                .spawn_blocking_task(move || connections.upsert_blocking(copy))
                .await;
            if let Ok(Err(error)) = saved {
                tracing::warn!(%error, "could not save the duplicated connection");
                input.deliver(SessionWindowInput::ShowToast(crate::i18n::gettext(
                    "The connection could not be duplicated.",
                )));
                return;
            }
            // A copy with no password still connects once the user types
            // one, so a keyring that refuses is reported rather than
            // undoing the copy.
            let carried = copy_secrets(secrets.as_ref(), source.id, copy_id, &name).await;
            input.deliver(SessionWindowInput::ReloadConnections);
            input.deliver(SessionWindowInput::ShowToast(if carried {
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
    pub(super) fn on_set_connection_group(&self, id: Uuid, group: Option<String>) {
        let group = group.map(|name| name.trim().to_owned()).filter(|name| !name.is_empty());
        let Some(mut saved) = self.saved_connection(id) else {
            return;
        };
        if saved.group == group {
            return;
        }
        saved.group = group;
        self.write_connection(saved, crate::i18n::gettext("The group could not be saved."));
    }

    /// Put a colour on a connection, or take the one it has off.
    ///
    /// The whole entry is rewritten because that is what the store
    /// takes, and it comes from the list the window already holds rather
    /// than from a re-read: the row that asked is showing that entry.
    pub(super) fn on_set_connection_color(&self, id: Uuid, color: Option<tablepro_storage::ConnectionColor>) {
        let Some(mut saved) = self.saved_connection(id) else {
            return;
        };
        if saved.color == color {
            return;
        }
        saved.color = color;
        self.write_connection(saved, crate::i18n::gettext("The colour could not be saved."));
    }

    /// Write one connection back and reload the list from disk, so the
    /// picker redraws from what was actually saved.
    fn write_connection(&self, saved: SavedConnection, failure: String) {
        let (Some(state), Some(input)) = (self.state(), self.input()) else {
            return;
        };
        let connections = state.services.storage.connections().clone();
        let tasks = state.services.tasks.clone();
        drop(state.services.tasks.spawn_task(async move {
            let written = tasks
                .spawn_blocking_task(move || connections.upsert_blocking(saved))
                .await;
            if let Ok(Err(error)) = written {
                tracing::warn!(%error, "could not save the connection");
                input.deliver(SessionWindowInput::ShowToast(failure));
            }
            input.deliver(SessionWindowInput::ReloadConnections);
        }));
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
        drop(state.services.tasks.spawn_task(async move {
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
                    crate::i18n::gettext("That file is not a TablePro connection export.")
                }
                Err(error) => {
                    tracing::warn!(%error, "the import task did not finish");
                    crate::i18n::gettext("The connections could not be imported.")
                }
            };
            input.deliver(SessionWindowInput::ReloadConnections);
            input.deliver(SessionWindowInput::ShowToast(message));
        }));
    }

    /// The list could not be read, so the user is told rather than shown
    /// an empty picker that looks like their connections vanished.
    pub(super) fn show_connection_list_banner(&self) {
        let (Some(state), Some(picker)) = (self.state(), self.imp().picker.get()) else {
            return;
        };
        let banner = picker.banner();
        let Some(content) =
            crate::ui::connection_list_banner::banner_content(&state.services.storage.connections().snapshot().state)
        else {
            banner.set_revealed(false);
            return;
        };
        banner.set_title(&content.title);
        banner.set_button_label(Some(&content.button_label));
        banner.set_revealed(true);
    }

    /// The keyring refused, so the entry stays and the user is offered
    /// another go rather than being left with orphaned secrets.
    pub(super) fn on_secret_delete_failed(&self, id: Uuid) {
        let Some(input) = self.input() else {
            return;
        };
        let toast = adw::Toast::new(&crate::i18n::gettext(
            "The stored passwords could not be deleted, so the connection was kept.",
        ));
        toast.set_button_label(Some(&crate::i18n::gettext("Retry")));
        toast.connect_button_clicked(move |_| input.deliver(SessionWindowInput::DeleteConnection(id)));
        self.imp().toast_overlay.add_toast(toast);
    }

    pub(super) fn on_reset_connection_list(&self) {
        let (Some(state), Some(input), Some(picker)) = (self.state(), self.input(), self.imp().picker.get()) else {
            return;
        };
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

        let store = state.services.storage.connections().clone();
        let tasks = state.services.tasks.clone();
        let banner = picker.banner();
        let toasts = self.imp().toast_overlay.get();
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "reset" {
                return;
            }
            let store = store.clone();
            let resetting =
                tasks.spawn_blocking_task(move || store.reset_unreadable_blocking(std::time::SystemTime::now()));
            let (banner, toasts, input) = (banner.clone(), toasts.clone(), input.clone());
            glib::spawn_future_local(async move {
                let error = match resetting.await {
                    Ok(Ok(moved)) => {
                        banner.set_revealed(false);
                        toasts.add_toast(adw::Toast::new(&crate::ui::connection_list_banner::reset_toast_text(
                            &moved,
                        )));
                        input.deliver(SessionWindowInput::ReloadConnections);
                        return;
                    }
                    Ok(Err(error)) => error.to_string(),
                    Err(error) => error.to_string(),
                };
                tracing::warn!(%error, "could not reset the saved connections");
                toasts.add_toast(adw::Toast::new(&crate::i18n::gettext_f(
                    "Could not reset the saved connections: {error}",
                    &[("error", &error)],
                )));
            });
        });
        dialog.present(Some(self));
    }
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
    secrets: Arc<dyn tablepro_core::credentials::SecretVault>,
    tasks: tablepro_session::runtime::Tasks,
    saved_queries: Option<tablepro_storage::SavedQueries>,
    id: Uuid,
    input: InputSender<SessionWindowInput>,
) {
    let spawner = tasks.clone();
    drop(spawner.spawn_task(async move {
        // Secrets first: an entry with no secrets is recoverable, a
        // secret with no entry is orphaned in the keyring.
        if let Err(error) = secrets.delete_connection(id).await {
            tracing::warn!(%error, "could not delete the connection secrets; keeping the entry");
            input.deliver(SessionWindowInput::SecretDeleteFailed(id));
            return;
        }
        let removed = tasks.spawn_blocking_task(move || connections.remove_blocking(id)).await;
        if let Ok(Err(error)) = removed {
            tracing::warn!(%error, "could not remove the saved connection");
        }
        // The queries saved here name tables only this database has, so
        // they go with it. A failure leaves them listed under the
        // connection's last name, which the user can still delete one
        // by one.
        if let Some(saved_queries) = saved_queries
            && let Err(error) = saved_queries.delete_for_connection(id).await
        {
            tracing::warn!(%error, "could not remove the connection's saved queries");
        }
        input.deliver(SessionWindowInput::ReloadConnections);
    }));
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

    use super::*;

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

    #[gtk4::test]
    fn an_export_is_read_whole() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("connections.json");
        std::fs::write(&path, br#"{"connections":[]}"#).expect("write");

        assert_eq!(read(&path).as_deref(), Ok(&br#"{"connections":[]}"#[..]));
    }
}
