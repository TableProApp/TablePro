use relm4::adw;
use relm4::gtk::prelude::*;
use tablepro_core::TableInfo;

use super::App;
use super::init_sidebar::refresh_visible;
use crate::services::sidebar_tree::{CollapseState, NodeKind, Reveal, build_nodes, reveal_target};
use crate::ui::sidebar_row::{GroupInit, SidebarObjectKind, SidebarRowInit, SidebarRowMsg};

pub(super) fn reveal_sidebar(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    reveal_with(split_view, generation, |split_view| split_view.set_show_sidebar(true));
}

fn reveal_sidebar_unless_overlay(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    reveal_with(split_view, generation, show_unless_overlay);
}

fn reveal_with(
    split_view: &adw::OverlaySplitView,
    generation: &std::rc::Rc<std::cell::Cell<u32>>,
    show: fn(&adw::OverlaySplitView),
) {
    let wanted = generation.get().wrapping_add(1);
    generation.set(wanted);
    if split_view.width() > 0 {
        show(split_view);
        return;
    }
    let generation = generation.clone();
    split_view.add_tick_callback(move |split_view, _| {
        if generation.get() != wanted {
            return relm4::gtk::glib::ControlFlow::Break;
        }
        if split_view.width() == 0 {
            return relm4::gtk::glib::ControlFlow::Continue;
        }
        show(split_view);
        relm4::gtk::glib::ControlFlow::Break
    });
}

fn sidebar_follows_connection(split_view: &adw::OverlaySplitView, toggle: &relm4::gtk::ToggleButton, connected: bool) {
    split_view.set_pin_sidebar(!connected);
    toggle.set_sensitive(connected);
}

fn show_unless_overlay(split_view: &adw::OverlaySplitView) {
    split_view.set_show_sidebar(!split_view.is_collapsed());
}

fn show_sidebar(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    generation.set(generation.get().wrapping_add(1));
    split_view.set_show_sidebar(true);
}

pub(super) fn hide_sidebar(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    generation.set(generation.get().wrapping_add(1));
    split_view.set_show_sidebar(false);
}

impl App {
    pub(super) fn show_sidebar_for_new_connection(&self) {
        self.set_sidebar_connected(true);
        reveal_sidebar_unless_overlay(&self.split_view, &self.sidebar_reveal);
    }

    pub(super) fn set_sidebar_connected(&self, connected: bool) {
        sidebar_follows_connection(&self.split_view, &self.sidebar_toggle, connected);
    }

    pub(super) fn repopulate_sidebar(&mut self, tables: &[TableInfo]) {
        self.sidebar_tables = tables.to_vec();
        let nodes = build_nodes(tables, &self.sidebar_views);
        let schema_filter_enabled = self.current_driver_id.as_deref() == Some("postgres");
        let timeout =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let source =
            crate::ui::sidebar_columns::ColumnSource::capture(self.connection_id, self.database.clone(), timeout);
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for node in &nodes {
            guard.push_back(row_for(
                node,
                &self.sidebar_collapsed.borrow(),
                schema_filter_enabled,
                source.clone(),
            ));
        }
        drop(guard);
        *self.sidebar_nodes.borrow_mut() = nodes;
        refresh_visible(
            &self.sidebar_nodes,
            &self.sidebar_collapsed,
            &self.sidebar_visible,
            &self.table_search.text(),
            &self.sidebar_hidden_schemas,
        );
        self.sidebar_factory.widget().invalidate_filter();
        self.schema_filter_button.set_visible(schema_filter_enabled);
        self.sync_sidebar_selection();
    }

    pub(super) fn toggle_sidebar_group(&mut self, key: &str) {
        if !self.table_search.text().is_empty() {
            return;
        }
        self.sidebar_collapsed.borrow_mut().toggle(key);
        let collapsed = self.sidebar_collapsed.borrow().is_collapsed(key);
        let row = self.sidebar_nodes.borrow().iter().position(|node| node.key == key);
        if let Some(row) = row {
            self.sidebar_factory.send(row, SidebarRowMsg::SetCollapsed(collapsed));
        }
        refresh_visible(
            &self.sidebar_nodes,
            &self.sidebar_collapsed,
            &self.sidebar_visible,
            &self.table_search.text(),
            &self.sidebar_hidden_schemas,
        );
        self.sidebar_factory.widget().invalidate_filter();
        self.persist_workspace_state();
    }

    pub(super) fn on_reveal_in_sidebar(&mut self) {
        let Some((schema, table)) = self.selected_browse_slot_table() else {
            self.show_toast(&crate::tr!("Open a table to reveal it in the sidebar."));
            return;
        };
        let plan = reveal_target(
            &self.sidebar_nodes.borrow(),
            &self.sidebar_collapsed.borrow(),
            &self.table_search.text(),
            &self.sidebar_hidden_schemas.borrow(),
            schema.as_deref(),
            &table,
        );
        match plan {
            Reveal::Missing => self.show_toast(
                &crate::tr!("{table} is not in the sidebar. Refresh the connection if it is new.")
                    .replace("{table}", &table),
            ),
            Reveal::HiddenBySchemaFilter => self.show_toast(
                &crate::tr!("The schema of {table} is hidden. Show it from the schema filter.")
                    .replace("{table}", &table),
            ),
            Reveal::Show {
                index,
                uncollapse,
                clear_search,
            } => {
                show_sidebar(&self.split_view, &self.sidebar_reveal);
                if clear_search {
                    self.table_search.set_text("");
                }
                for key in &uncollapse {
                    self.toggle_sidebar_group(key);
                }
                refresh_visible(
                    &self.sidebar_nodes,
                    &self.sidebar_collapsed,
                    &self.sidebar_visible,
                    &self.table_search.text(),
                    &self.sidebar_hidden_schemas,
                );
                self.sidebar_factory.widget().invalidate_filter();
                self.focus_sidebar_row(index);
            }
        }
    }

    fn focus_sidebar_row(&self, index: usize) {
        let listbox = self.sidebar_factory.widget();
        if let Some(row) = listbox.row_at_index(index as i32) {
            listbox.select_row(Some(&row));
            row.grab_focus();
        }
    }

    pub(super) fn restore_sidebar_state(&self) {
        let state = self
            .workspace_target()
            .and_then(|(id, database)| self.workspace.load_database(id, &database));
        *self.sidebar_collapsed.borrow_mut() = CollapseState::from_keys(
            state
                .as_ref()
                .map(|state| state.collapsed_groups.clone())
                .unwrap_or_default(),
        );
        *self.sidebar_hidden_schemas.borrow_mut() = state
            .map(|state| state.hidden_schemas.into_iter().collect())
            .unwrap_or_default();
    }

    pub(super) fn hide_sidebar_schema(&mut self, schema: &str, sender: &relm4::ComponentSender<App>) {
        if schema.is_empty() || schema.len() > 256 {
            return;
        }
        let is_schema = self
            .sidebar_nodes
            .borrow()
            .iter()
            .any(|node| matches!(node.kind, NodeKind::Schema) && node.schema.as_deref() == Some(schema));
        if !is_schema {
            return;
        }
        self.sidebar_hidden_schemas.borrow_mut().insert(schema.to_string());
        self.refresh_schema_filter(sender);
        self.persist_workspace_state();
    }

    pub(super) fn show_sidebar_schema(&mut self, schema: &str, sender: &relm4::ComponentSender<App>) {
        self.sidebar_hidden_schemas.borrow_mut().remove(schema);
        self.refresh_schema_filter(sender);
        self.persist_workspace_state();
    }

    pub(super) fn show_all_sidebar_schemas(&mut self, sender: &relm4::ComponentSender<App>) {
        self.sidebar_hidden_schemas.borrow_mut().clear();
        self.refresh_schema_filter(sender);
        self.persist_workspace_state();
    }

    pub(super) fn rebuild_schema_filter_popover(&self, sender: &relm4::ComponentSender<App>) {
        while let Some(child) = self.schema_filter_list.first_child() {
            self.schema_filter_list.remove(&child);
        }
        let heading = relm4::gtk::Label::builder()
            .label(crate::tr!("Hidden schemas"))
            .xalign(0.0)
            .build();
        self.schema_filter_list.append(&heading);
        let mut hidden: Vec<String> = self.sidebar_hidden_schemas.borrow().iter().cloned().collect();
        hidden.sort();
        if hidden.is_empty() {
            let empty = relm4::gtk::Label::builder()
                .label(crate::tr!("No schemas are hidden"))
                .xalign(0.0)
                .build();
            self.schema_filter_list.append(&empty);
            return;
        }
        let sender_for_all = sender.clone();
        let show_all = relm4::gtk::Button::with_label(&crate::tr!("Show all schemas"));
        show_all.connect_clicked(move |_| sender_for_all.input(super::AppMsg::ShowAllSidebarSchemas));
        self.schema_filter_list.append(&show_all);
        for schema in hidden {
            let label = crate::tr!("Show {schema}").replace("{schema}", &schema);
            let button = relm4::gtk::Button::with_label(&label);
            let sender_for_schema = sender.clone();
            button.connect_clicked(move |_| sender_for_schema.input(super::AppMsg::ShowSidebarSchema(schema.clone())));
            self.schema_filter_list.append(&button);
        }
    }

    fn refresh_schema_filter(&self, sender: &relm4::ComponentSender<App>) {
        refresh_visible(
            &self.sidebar_nodes,
            &self.sidebar_collapsed,
            &self.sidebar_visible,
            &self.table_search.text(),
            &self.sidebar_hidden_schemas,
        );
        self.sidebar_factory.widget().invalidate_filter();
        self.rebuild_schema_filter_popover(sender);
    }
}

fn row_for(
    node: &crate::services::sidebar_tree::TreeNode,
    collapsed: &crate::services::sidebar_tree::CollapseState,
    schema_filter_enabled: bool,
    column_source: Option<crate::ui::sidebar_columns::ColumnSource>,
) -> SidebarRowInit {
    use crate::services::sidebar_tree::{GroupKind, NodeKind};
    let (kind, group) = match &node.kind {
        NodeKind::Table { .. } => (SidebarObjectKind::Table, None),
        NodeKind::View { .. } => (SidebarObjectKind::View, None),
        NodeKind::Schema | NodeKind::Group(_) => (
            if schema_filter_enabled && node.schema.is_some() && matches!(node.kind, NodeKind::Schema) {
                SidebarObjectKind::Schema
            } else {
                SidebarObjectKind::Group
            },
            Some(GroupInit {
                label: node.label.clone(),
                count: node.count,
                collapsed: collapsed.is_collapsed(&node.key),
                actions: matches!(node.kind, NodeKind::Group(GroupKind::Tables)),
            }),
        ),
    };
    let name = match &node.kind {
        NodeKind::Table { name, .. } | NodeKind::View { name, .. } => name.clone(),
        _ => node.key.clone(),
    };
    SidebarRowInit {
        info: TableInfo {
            schema: node.schema.clone(),
            name,
        },
        kind,
        depth: node.depth,
        group,
        column_source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_sidebar_stays_closed_in_a_narrow_window_and_never_opens_empty() {
        relm4::adw::init().unwrap();
        let split_view = adw::OverlaySplitView::new();
        let toggle = relm4::gtk::ToggleButton::new();
        sidebar_follows_connection(&split_view, &toggle, false);
        split_view.set_show_sidebar(false);
        split_view.set_collapsed(true);
        split_view.set_collapsed(false);
        assert!(
            !split_view.shows_sidebar(),
            "widening without a connection keeps the empty sidebar closed"
        );
        assert!(!toggle.is_sensitive());

        sidebar_follows_connection(&split_view, &toggle, true);
        split_view.set_collapsed(true);
        show_unless_overlay(&split_view);
        assert!(
            !split_view.shows_sidebar(),
            "connecting in a narrow window does not cover the workspace"
        );
        assert!(toggle.is_sensitive());
        split_view.set_collapsed(false);
        assert!(
            split_view.shows_sidebar(),
            "widening while connected docks the sidebar again"
        );
    }
}

#[cfg(test)]
mod explicit_reveal_tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn an_explicit_reveal_opens_the_sidebar_in_a_narrow_window() {
        relm4::adw::init().unwrap();
        let split = adw::OverlaySplitView::builder()
            .collapsed(true)
            .show_sidebar(false)
            .build();
        let generation = std::rc::Rc::new(std::cell::Cell::new(3));
        show_sidebar(&split, &generation);
        assert!(split.shows_sidebar());
        assert_eq!(generation.get(), 4);
        hide_sidebar(&split, &generation);
        assert!(!split.shows_sidebar());
    }
}
