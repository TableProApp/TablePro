use relm4::adw::prelude::*;
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
                registry: self.registry.clone(),
            })
            .forward(sender.input_sender(), |out| match out {
                ConnectDialogOutput::Connected { tables, driver_id } => AppMsg::Connected { tables, driver_id },
                ConnectDialogOutput::Closed => AppMsg::DialogClosed,
            });
        dialog.widget().present(Some(&self.window));
        self.dialog = Some(dialog);
    }

    pub(super) fn on_connected(&mut self, tables: Vec<TableInfo>, driver_id: String, sender: ComponentSender<Self>) {
        self.dialog = None;
        self.connected = true;
        self.current_driver_id = Some(driver_id.clone());
        self.read_only = database_service::instance().is_active_read_only();
        self.read_only_badge.set_visible(self.read_only);
        self.split_view.set_show_sidebar(true);
        self.disconnect_action.set_enabled(true);
        self.table_search.set_text("");
        // Build Browse + Editor tab roots eagerly so the ViewSwitcher
        // always shows both peers (single-tab switcher would be noise).
        self.ensure_browse_root(sender.clone());
        self.ensure_editor_page(sender.clone());
        self.view_switcher_bar.set_reveal(true);
        self.view_stack.set_visible_child_name("browse");
        self.content_holder.set_content(Some(&self.view_stack));
        self.table_names = tables.iter().map(|t| t.name.clone()).collect();
        tracing::info!(driver = %driver_id, table_count = tables.len(), "workspace ready");
        self.repopulate_sidebar(&tables);
        self.rebuild_schema_buffer();
        self.refresh_window_title();
        // Restore browse tabs persisted from the prior session for this
        // connection (if any) — Q4. Empty state otherwise.
        if let Some(connection_id) = database_service::instance().active_id() {
            self.restore_browse_tabs(connection_id, sender.clone());
        }
        sender.input(AppMsg::ReloadConnections);
    }

    pub(super) fn on_disconnect(&mut self, sender: ComponentSender<Self>) {
        // Tear down browse tabs first (also persists state) before we
        // drop the connection — persist needs the active connection_id.
        self.teardown_browse_tabs();
        let svc = database_service::instance();
        if let Some(id) = svc.active_id() {
            svc.remove(id);
        } else {
            svc.clear_all();
        }
        self.cancel_all_editor_runs();
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
        // Tear down the Editor view-stack page so the next connection
        // builds a fresh editor (with its own tabs / persisted state).
        if let Some(root) = self.editor_root.take()
            && self.editor_page_added.get()
        {
            self.view_stack.remove(&root);
            self.editor_page_added.set(false);
        }
        self.editor_tab_view = None;
        self.editor_tabs.borrow_mut().clear();
        // Hide the ViewSwitcherBar so the welcome view occupies the full
        // toolbar — the bar is only meaningful in the connected state.
        self.view_switcher_bar.set_reveal(false);
        self.show_welcome_page(sender);
        tracing::info!("disconnected");
    }

    pub(super) fn on_reload_connections(&self, sender: ComponentSender<Self>) {
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    if let Ok(connections) = tablepro_storage::load_connections().await {
                        sender_clone.input(AppMsg::ConnectionsLoaded(connections));
                    }
                })
                .drop_on_shutdown()
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
        // It's irreversible — Undo can't recover the keyring entries — so
        // we confirm before acting (gated by preferences::confirm_destructive
        // to match the row-delete pattern).
        if !crate::services::preferences::load().confirm_destructive {
            execute_delete_connection(id, sender);
            return;
        }

        let connection_name = self
            .saved_connections
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.name.clone())
            .unwrap_or_else(|| crate::tr!("this connection"));
        let title = crate::tr!("Delete {name}?").replace("{name}", &connection_name);
        let body = crate::tr!(
            "The saved entry and any stored passwords will be removed from your keyring. This cannot be undone."
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("delete", &crate::tr!("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let sender_for_response = sender;
        dialog.connect_response(None, move |dialog, response| {
            dialog.close();
            if response != "delete" {
                return;
            }
            execute_delete_connection(id, sender_for_response.clone());
        });
        dialog.present(Some(&self.window));
    }

    pub(super) fn on_open_saved(&self, saved: SavedConnection, sender: ComponentSender<Self>) {
        self.connections_popover.popdown();
        self.set_loading_page(
            &crate::tr!("Connecting…"),
            &crate::tr!("Opening {name}").replace("{name}", &saved.name),
        );
        let driver_id = saved.driver_id.clone();
        let registry = self.registry.clone();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match connection_service::open_saved(registry, saved).await {
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
                self.reconnect_banner.set_title(
                    &crate::tr!("Connection lost — reconnecting (attempt {n}, will keep retrying)")
                        .replace("{n}", &attempt.to_string()),
                );
                self.reconnect_banner.set_revealed(true);
            }
            _ => self.reconnect_banner.set_revealed(false),
        }
    }

    pub(super) fn refresh_window_title(&self) {
        // Subtitle: "<table> · <connection> · <driver>" when a browse tab
        // is active; "<connection> · <driver>" otherwise. Window title
        // keeps the "— TablePro" suffix for shell window-list identity.
        let metadata = database_service::instance().active_metadata();
        let connection_name = metadata.as_ref().map(|m| m.name.as_str());
        let active = self.selected_browse_slot_table();
        let table_pair = active.as_ref().map(|(s, t)| (s.as_deref(), t.as_str()));
        let (os_title, subtitle) = match (connection_name, &self.current_driver_id, table_pair) {
            (Some(name), Some(driver), Some((schema, table))) => {
                let label = qualified_label(schema, table);
                (
                    format!("{label} · {name} — TablePro"),
                    format!("{label} · {name} · {driver}"),
                )
            }
            (Some(name), Some(driver), None) => (format!("{name} — TablePro"), format!("{name} · {driver}")),
            (None, Some(driver), _) => (format!("{driver} — TablePro"), driver.clone()),
            _ => ("TablePro".to_string(), String::new()),
        };
        self.window.set_title(Some(&os_title));
        self.window_title.set_subtitle(&subtitle);
    }
}

/// Performs the actual disk + keyring teardown for a saved connection.
/// Extracted from `on_delete_connection` so the confirm-yes branch and
/// the prefs-disabled branch share one implementation.
fn execute_delete_connection(id: Uuid, sender: ComponentSender<App>) {
    let sender_clone = sender.clone();
    sender.command(move |_, shutdown| {
        shutdown
            .register(async move {
                let _ = tablepro_storage::delete_connection(id).await;
                let _ = tablepro_storage::delete_password(id).await;
                let _ = tablepro_storage::delete_ssh_password(id).await;
                let _ = tablepro_storage::delete_ssh_passphrase(id).await;
                sender_clone.input(AppMsg::ReloadConnections);
            })
            .drop_on_shutdown()
    });
}
