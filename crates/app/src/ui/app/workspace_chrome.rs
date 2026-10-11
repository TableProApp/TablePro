use relm4::adw::prelude::*;

use crate::services::database_service::ConnectionMetadata;

use super::{App, qualified_label};
use crate::services::sidebar_tree::NodeKind;

impl App {
    pub(super) fn on_switch_to_recent_tab(&self) {
        let Some(view) = self.workspace_tab_view.as_ref() else {
            return;
        };
        let mut walk = self.recent_walk.borrow_mut();
        let walk = walk.get_or_insert_with(|| self.recent_pages.borrow().walk());
        if let Some(page) = walk.step(|page| view.page_position(page) >= 0) {
            view.set_selected_page(&page);
        }
    }

    pub(super) fn on_end_recent_tab_walk(&self) {
        if self.recent_walk.borrow_mut().take().is_none() {
            return;
        }
        if let Some(page) = self.workspace_tab_view.as_ref().and_then(|view| view.selected_page()) {
            self.recent_pages.borrow_mut().touch(&page);
        }
    }

    pub(super) fn on_workspace_tabs_changed(&self) {
        if self.recent_walk.borrow().is_none()
            && let Some(page) = self.workspace_tab_view.as_ref().and_then(|view| view.selected_page())
        {
            self.recent_pages.borrow_mut().touch(&page);
        }
        self.persist_workspace_state();
        self.refresh_window_title();
        self.sync_sidebar_selection();
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
        let metadata = self.window_metadata();
        let connection_name = metadata.as_ref().map(|m| m.name.as_str());
        let active = self.selected_browse_slot_table();
        let table_pair = active.as_ref().map(|(s, t)| (s.as_deref(), t.as_str()));
        let (mut os_title, subtitle) = match (connection_name, &self.current_driver_id, table_pair) {
            (Some(name), Some(driver), Some((schema, table))) => {
                let label = qualified_label(schema, table);
                (
                    format!("{label} · {name} — BookiE"),
                    format_connection_subtitle(name, driver, metadata.as_ref()),
                )
            }
            (Some(name), Some(driver), None) => (
                format!("{name} — BookiE"),
                format_connection_subtitle(name, driver, metadata.as_ref()),
            ),
            (None, Some(driver), _) => (format!("{driver} — BookiE"), driver.clone()),
            _ => ("BookiE".to_string(), String::new()),
        };
        // GNOME Text Editor convention: prefix the OS-level window
        // title with "• " when any open document has unsaved changes,
        // so the dirty state is visible from the Activities overview /
        // Alt-Tab without needing the tab to be focused.
        if self.window_has_pending() {
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
                self.sidebar_title.set_title(&crate::tr!("Tables"));
            }
        }
    }

    /// Highlight the sidebar row matching the active Browse tab's
    /// `(schema, table)`. When the active tab is an Editor (or there
    /// are no tabs), clear the sidebar selection — leaving a stale
    /// row highlighted while the user is in the editor would imply
    /// the editor is showing that table's data, which it isn't.
    pub(crate) fn sync_sidebar_selection(&self) {
        let listbox = self.sidebar_factory.widget();
        let Some((schema, table)) = self.selected_browse_slot_table() else {
            listbox.unselect_all();
            return;
        };
        let nodes = self.sidebar_nodes.borrow();
        let found = nodes.iter().position(|node| match &node.kind {
            NodeKind::Table {
                schema: node_schema,
                name,
            }
            | NodeKind::View {
                schema: node_schema,
                name,
            } => name.as_str() == table && node_schema.as_deref() == schema.as_deref(),
            _ => false,
        });
        if let Some(row) = found.and_then(|index| listbox.row_at_index(index as i32)) {
            listbox.select_row(Some(&row));
        }
    }
}

fn format_connection_subtitle(name: &str, driver: &str, metadata: Option<&ConnectionMetadata>) -> String {
    let mut parts = vec![name.to_string(), driver.to_string()];
    if let Some(meta) = metadata {
        parts.push(meta.environment.display_name().to_string());
        if let Some(version) = meta.server_version.as_deref().filter(|v| !v.is_empty()) {
            parts.push(version.to_string());
        }
        if meta.read_only {
            parts.push("read-only".into());
        }
    }
    parts.join(" · ")
}
