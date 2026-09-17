use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{Component, ComponentController, ComponentSender, adw};

use tablepro_core::TableInfo;
use tablepro_storage::SavedConnection;
use uuid::Uuid;

use crate::services::database_service::ConnectionHealth;
use crate::services::{connection_service, database_service};
use crate::ui::connect_dialog::{ConnectDialog, ConnectDialogInit, ConnectDialogOutput};

use super::{App, AppMsg, qualified_label};

impl App {
    pub(super) fn on_open_connect(&mut self, sender: ComponentSender<Self>) {
        let dialog = ConnectDialog::builder()
            .launch(ConnectDialogInit {
                storage: self.storage.clone(),
                registry: self.registry.clone(),
                settings: self.settings.clone(),
                tasks: self.tasks.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                ConnectDialogOutput::Connected { tables, driver_id } => AppMsg::Connected { tables, driver_id },
                ConnectDialogOutput::Warning(message) => AppMsg::ShowToast(message),
                ConnectDialogOutput::Closed => AppMsg::DialogClosed,
            });
        dialog.widget().present(Some(&self.window));
        self.dialog = Some(dialog);
    }

    pub(super) fn on_connected(&mut self, tables: Vec<TableInfo>, driver_id: String, sender: ComponentSender<Self>) {
        self.dismiss_loading_page();
        self.dialog = None;
        self.connected = true;
        self.current_driver_id = Some(driver_id.clone());
        self.read_only = database_service::instance().is_active_read_only();
        self.read_only_badge.set_visible(self.read_only);
        self.split_view.set_show_sidebar(true);
        self.disconnect_action.set_enabled(true);
        self.table_search.set_text("");
        // Build the unified workspace tab tree (Browse + Editor share one
        // strip). Empty state shows "Select a table" until the user opens
        // a tab via sidebar click or Ctrl+T.
        self.ensure_workspace_root(sender.clone());
        self.content_holder.set_content(Some(&self.workspace_outer_stack));
        self.table_names = tables.iter().map(|t| t.name.clone()).collect();
        tracing::info!(driver = %driver_id, table_count = tables.len(), "workspace ready");
        self.repopulate_sidebar(&tables);
        self.rebuild_schema_buffer();
        self.refresh_window_title();
        // Restore tabs (browse + editor) persisted from the prior session
        // for this connection.
        if let Some(connection_id) = database_service::instance().active_id() {
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
        // Block disconnect when any tab has pending changes. The
        // teardown below clears all tracker registries, so dropping
        // the connection mid-edit silently destroys the user's work.
        // Confirm via an AlertDialog mirroring the window-close-with-
        // pending and F5-with-pending paths.
        let has_pending = crate::services::change_tracker::any_pending_globally()
            || crate::services::structure_tracker::any_pending_globally();
        if has_pending {
            let dialog = adw::AlertDialog::new(
                Some(&crate::i18n::gettext("Discard pending changes?")),
                Some(&crate::i18n::gettext(
                    "Disconnecting will close every tab and drop every unsaved row edit and DDL change.",
                )),
            );
            dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
            dialog.add_response("discard", &crate::i18n::gettext("Discard and disconnect"));
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            let sender_for_resp = sender.clone();
            dialog.connect_response(None, move |dlg, response| {
                dlg.close();
                if response == "discard" {
                    sender_for_resp.input(AppMsg::ForceDisconnect);
                }
            });
            dialog.present(Some(&self.window));
            return;
        }
        self.do_disconnect(sender);
    }

    /// Skip the dirty check and tear the connection down. Reachable
    /// either from the AlertDialog "Discard and disconnect" branch
    /// or from a clean `Disconnect` when no tracker has pending
    /// changes.
    pub(super) fn do_disconnect(&mut self, sender: ComponentSender<Self>) {
        // Persist + tear down workspace tabs before dropping the
        // connection (persist needs the active connection_id).
        self.teardown_workspace_tabs();
        // Drop reopen-stack entries — they reference tables in the
        // connection we're about to release. Reopening one against a
        // different connection would target a non-existent table.
        self.clear_closed_tabs_stack();
        let svc = database_service::instance();
        if let Some(id) = svc.active_id() {
            svc.remove(id);
        } else {
            svc.clear_all();
        }
        self.schema_buffer.set_text(crate::ui::editor::SQL_KEYWORDS);
        self.current_driver_id = None;
        self.read_only = false;
        self.read_only_badge.set_visible(false);
        self.connected = false;
        self.split_view.set_show_sidebar(false);
        self.disconnect_action.set_enabled(false);
        self.refresh_window_title();
        self.table_search.set_text("");
        self.sidebar_schemas.borrow_mut().clear();
        self.sidebar_factory.guard().clear();
        self.show_welcome_page(sender);
        tracing::info!("disconnected");
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
        let mut guard = self.connections_factory.guard();
        guard.clear();
        for saved in connections {
            guard.push_back(saved.clone());
        }
        drop(guard);
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

    pub(super) fn on_poll_health(&mut self) {
        let current = database_service::instance().active_health();
        if current != self.health_state {
            self.refresh_health_banner(current.clone());
            self.health_state = current;
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
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
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
                })
                .drop_on_shutdown()
        });
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
        let connections = self.storage.connections().clone();
        let tasks = self.tasks.clone();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let written = tasks
                        .spawn_blocking_task(move || connections.upsert_blocking(saved))
                        .await;
                    if let Ok(Err(error)) = written {
                        tracing::warn!(%error, "could not save the connection colour");
                        sender_clone.input(AppMsg::ShowToast(crate::i18n::gettext(
                            "The colour could not be saved.",
                        )));
                    }
                    sender_clone.input(AppMsg::ReloadConnections);
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_open_saved(&mut self, saved: SavedConnection, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        self.set_loading_page(
            &crate::i18n::gettext("Connecting…"),
            &crate::i18n::gettext_f("Opening {name}", &[("name", &saved.name)]),
        );
        let driver_id = saved.driver_id.clone();
        let registry = self.registry.clone();
        let secrets = self.storage.secrets().clone();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match connection_service::open_saved(registry, secrets, saved).await {
                        Ok(tables) => sender_clone.input(AppMsg::Connected { tables, driver_id }),
                        Err(e) => sender_clone.input(AppMsg::LoadFailed(None, e)),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn repopulate_sidebar(&mut self, tables: &[TableInfo]) {
        {
            let mut schemas = self.sidebar_schemas.borrow_mut();
            schemas.clear();
            schemas.extend(tables.iter().map(|t| t.schema.clone()));
        }
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for table in tables {
            guard.push_back(table.clone());
        }
        drop(guard);
        self.sidebar_factory.widget().invalidate_headers();
    }

    /// Surfaces connection health via `adw::Banner` only when degraded —
    /// healthy/disconnected states show no chrome, matching GNOME apps that
    /// reserve banners for "abnormal, user-actionable" situations (Files
    /// uses the same pattern for unmounted volumes).
    pub(super) fn refresh_health_banner(&self, health: Option<ConnectionHealth>) {
        match health {
            Some(ConnectionHealth::Reconnecting { attempt }) => {
                self.reconnect_banner.set_title(&crate::i18n::gettext_f(
                    "Connection lost. Reconnecting (attempt {n}, will keep retrying)",
                    &[("n", &attempt.to_string())],
                ));
                self.reconnect_banner.set_revealed(true);
            }
            _ => self.reconnect_banner.set_revealed(false),
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
        let metadata = database_service::instance().active_metadata();
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
        if crate::services::change_tracker::any_pending_globally() {
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

/// Performs the actual disk + keyring teardown for a saved connection.
/// Extracted from `on_delete_connection` so the confirm-yes branch and
/// the prefs-disabled branch share one implementation.
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
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
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
            })
            .drop_on_shutdown()
    });
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
