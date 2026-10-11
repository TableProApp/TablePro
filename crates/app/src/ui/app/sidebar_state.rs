use relm4::gtk::prelude::*;
use tablepro_core::TableInfo;

use super::App;
use super::init_sidebar::refresh_visible;
use crate::services::sidebar_tree::{CollapseState, build_nodes};
use crate::ui::sidebar_row::{GroupInit, SidebarObjectKind, SidebarRowInit, SidebarRowMsg};

impl App {
    pub(super) fn repopulate_sidebar(&mut self, tables: &[TableInfo]) {
        self.sidebar_tables = tables.to_vec();
        let nodes = build_nodes(tables, &self.sidebar_views);
        let mut guard = self.sidebar_factory.guard();
        guard.clear();
        for node in &nodes {
            guard.push_back(row_for(node, &self.sidebar_collapsed.borrow()));
        }
        drop(guard);
        *self.sidebar_nodes.borrow_mut() = nodes;
        refresh_visible(
            &self.sidebar_nodes,
            &self.sidebar_collapsed,
            &self.sidebar_visible,
            &self.table_search.text(),
        );
        self.sidebar_factory.widget().invalidate_filter();
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
        );
        self.sidebar_factory.widget().invalidate_filter();
        self.persist_workspace_state();
    }

    pub(super) fn restore_sidebar_collapse(&self) {
        let saved = self
            .connection_id
            .and_then(|id| self.workspace.load_connection(id))
            .map(|state| state.collapsed_groups)
            .unwrap_or_default();
        *self.sidebar_collapsed.borrow_mut() = CollapseState::from_keys(saved);
    }
}

fn row_for(
    node: &crate::services::sidebar_tree::TreeNode,
    collapsed: &crate::services::sidebar_tree::CollapseState,
) -> SidebarRowInit {
    use crate::services::sidebar_tree::{GroupKind, NodeKind};
    let (kind, group) = match &node.kind {
        NodeKind::Table { .. } => (SidebarObjectKind::Table, None),
        NodeKind::View { .. } => (SidebarObjectKind::View, None),
        NodeKind::Schema | NodeKind::Group(_) => (
            SidebarObjectKind::Group,
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
