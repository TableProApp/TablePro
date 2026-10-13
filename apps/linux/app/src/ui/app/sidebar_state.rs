use relm4::adw;
use relm4::gtk::prelude::*;
use tablepro_core::TableInfo;

use super::App;
use super::init_sidebar::refresh_visible;
use crate::services::sidebar_tree::{CollapseState, NodeKind, build_nodes};
use crate::ui::sidebar_row::{GroupInit, SidebarObjectKind, SidebarRowInit, SidebarRowMsg};

pub(super) fn reveal_sidebar(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    let wanted = generation.get().wrapping_add(1);
    generation.set(wanted);
    if split_view.width() > 0 {
        split_view.set_show_sidebar(true);
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
        split_view.set_show_sidebar(true);
        relm4::gtk::glib::ControlFlow::Break
    });
}

pub(super) fn hide_sidebar(split_view: &adw::OverlaySplitView, generation: &std::rc::Rc<std::cell::Cell<u32>>) {
    generation.set(generation.get().wrapping_add(1));
    split_view.set_show_sidebar(false);
}

impl App {
    pub(super) fn repopulate_sidebar(&mut self, tables: &[TableInfo]) {
        self.sidebar_tables = tables.to_vec();
        let nodes = build_nodes(tables, &self.sidebar_views);
        let schema_filter_enabled = self.current_driver_id.as_deref() == Some("postgres");
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for node in &nodes {
            guard.push_back(row_for(node, &self.sidebar_collapsed.borrow(), schema_filter_enabled));
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

    pub(super) fn restore_sidebar_state(&self) {
        let state = self.connection_id.and_then(|id| self.workspace.load_connection(id));
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
    }
}
