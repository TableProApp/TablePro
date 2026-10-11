use std::collections::{BTreeSet, HashSet};

use tablepro_core::TableInfo;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupKind {
    Tables,
    Views,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeKind {
    Schema,
    Group(GroupKind),
    Table { schema: Option<String>, name: String },
    View { schema: Option<String>, name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeNode {
    pub depth: u8,
    pub key: String,
    pub label: String,
    pub kind: NodeKind,
    pub schema: Option<String>,
    pub count: usize,
}

impl TreeNode {
    fn qualified_name(&self) -> Option<String> {
        match &self.kind {
            NodeKind::Table { schema, name } | NodeKind::View { schema, name } => Some(match schema {
                Some(schema) => format!("{schema}.{name}"),
                None => name.clone(),
            }),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CollapseState(HashSet<String>);

impl CollapseState {
    pub fn toggle(&mut self, key: &str) {
        if !self.0.remove(key) {
            self.0.insert(key.to_string());
        }
    }

    pub fn is_collapsed(&self, key: &str) -> bool {
        self.0.contains(key)
    }

    pub fn keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = self.0.iter().cloned().collect();
        keys.sort();
        keys
    }

    pub fn from_keys(keys: impl IntoIterator<Item = String>) -> Self {
        Self(keys.into_iter().collect())
    }
}

fn schema_names(tables: &[TableInfo], views: &[TableInfo]) -> BTreeSet<Option<String>> {
    tables.iter().chain(views).map(|object| object.schema.clone()).collect()
}

pub fn build_nodes(tables: &[TableInfo], views: &[TableInfo]) -> Vec<TreeNode> {
    let schemas = schema_names(tables, views);
    let several_schemas = schemas.iter().filter(|schema| schema.is_some()).count() > 1;
    let mut nodes = Vec::new();
    for schema in &schemas {
        let in_schema = |object: &&TableInfo| &object.schema == schema;
        let schema_tables: Vec<&TableInfo> = tables.iter().filter(in_schema).collect();
        let schema_views: Vec<&TableInfo> = views.iter().filter(in_schema).collect();
        let prefix = format!("schema:{}", key_part(schema.as_deref().unwrap_or_default()));
        let mut depth = 0;
        if several_schemas {
            nodes.push(TreeNode {
                depth,
                key: prefix.clone(),
                label: schema.clone().unwrap_or_default(),
                kind: NodeKind::Schema,
                schema: schema.clone(),
                count: schema_tables.len() + schema_views.len(),
            });
            depth += 1;
        }
        push_group(&mut nodes, depth, &prefix, GroupKind::Tables, &schema_tables);
        push_group(&mut nodes, depth, &prefix, GroupKind::Views, &schema_views);
    }
    nodes
}

fn push_group(nodes: &mut Vec<TreeNode>, depth: u8, prefix: &str, group: GroupKind, objects: &[&TableInfo]) {
    if objects.is_empty() {
        return;
    }
    let (suffix, label) = match group {
        GroupKind::Tables => ("tables", crate::tr!("Tables")),
        GroupKind::Views => ("views", crate::tr!("Views")),
    };
    nodes.push(TreeNode {
        depth,
        key: format!("{prefix}/{suffix}"),
        label,
        kind: NodeKind::Group(group),
        schema: objects.first().and_then(|object| object.schema.clone()),
        count: objects.len(),
    });
    for object in objects {
        let (schema, name) = (object.schema.clone(), object.name.clone());
        nodes.push(TreeNode {
            depth: depth + 1,
            key: format!("{prefix}/{suffix}/{}", key_part(&name)),
            label: name.clone(),
            kind: match group {
                GroupKind::Tables => NodeKind::Table { schema, name },
                GroupKind::Views => NodeKind::View { schema, name },
            },
            schema: object.schema.clone(),
            count: 0,
        });
    }
}

fn key_part(raw: &str) -> String {
    raw.replace('%', "%25").replace('/', "%2F").replace(':', "%3A")
}

fn ancestor_keys(node: &TreeNode) -> Vec<String> {
    let mut keys = Vec::new();
    let mut path = node.key.as_str();
    while let Some((parent, _)) = path.rsplit_once('/') {
        keys.push(parent.to_string());
        path = parent;
    }
    keys
}

pub fn visible_nodes(nodes: &[TreeNode], collapsed: &CollapseState, query: &str) -> Vec<usize> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return (0..nodes.len())
            .filter(|index| {
                ancestor_keys(&nodes[*index])
                    .iter()
                    .all(|key| !collapsed.is_collapsed(key))
            })
            .collect();
    }
    let matching: Vec<usize> = (0..nodes.len())
        .filter(|index| {
            nodes[*index]
                .qualified_name()
                .is_some_and(|name| name.to_lowercase().contains(&query))
        })
        .collect();
    let mut shown: HashSet<usize> = matching.iter().copied().collect();
    for index in &matching {
        for key in ancestor_keys(&nodes[*index]) {
            if let Some(parent) = nodes.iter().position(|node| node.key == key) {
                shown.insert(parent);
            }
        }
    }
    (0..nodes.len()).filter(|index| shown.contains(index)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(schema: Option<&str>, name: &str) -> TableInfo {
        TableInfo {
            schema: schema.map(str::to_string),
            name: name.to_string(),
        }
    }

    fn labels(nodes: &[TreeNode], indexes: &[usize]) -> Vec<String> {
        indexes
            .iter()
            .map(|index| format!("{}{}", "  ".repeat(nodes[*index].depth as usize), nodes[*index].label))
            .collect()
    }

    fn all(nodes: &[TreeNode]) -> Vec<usize> {
        (0..nodes.len()).collect()
    }

    #[test]
    fn a_single_schema_shows_groups_at_the_top_without_a_schema_row() {
        let nodes = build_nodes(&[info(None, "users"), info(None, "orders")], &[info(None, "recent")]);
        assert_eq!(
            labels(&nodes, &all(&nodes)),
            ["Tables", "  users", "  orders", "Views", "  recent"]
        );
    }

    #[test]
    fn several_schemas_nest_groups_and_objects_under_each_schema() {
        let nodes = build_nodes(
            &[info(Some("public"), "users"), info(Some("audit"), "events")],
            &[info(Some("public"), "recent")],
        );
        assert_eq!(
            labels(&nodes, &all(&nodes)),
            [
                "audit",
                "  Tables",
                "    events",
                "public",
                "  Tables",
                "    users",
                "  Views",
                "    recent"
            ]
        );
    }

    #[test]
    fn groups_and_schemas_carry_how_many_objects_they_hold() {
        let tables = [info(Some("a"), "t1"), info(Some("a"), "t2"), info(Some("b"), "t3")];
        let views = [info(Some("a"), "v1")];
        let nodes = build_nodes(&tables, &views);
        let count_of = |key: &str| nodes.iter().find(|node| node.key == key).map(|node| node.count);
        assert_eq!(count_of("schema:a"), Some(3));
        assert_eq!(count_of("schema:a/tables"), Some(2));
        assert_eq!(count_of("schema:a/views"), Some(1));
        assert_eq!(count_of("schema:b/tables"), Some(1));
    }

    #[test]
    fn a_schema_or_table_name_with_separators_cannot_collide_with_another_node() {
        let tables = [
            info(Some("a"), "t"),
            info(Some("a/b"), "u"),
            info(Some("x/tables"), "v"),
            info(Some("x"), "w"),
            info(Some("x"), "p/q"),
        ];
        let nodes = build_nodes(&tables, &[]);
        let keys: HashSet<&str> = nodes.iter().map(|node| node.key.as_str()).collect();
        assert_eq!(keys.len(), nodes.len());

        let mut collapsed = CollapseState::default();
        collapsed.toggle("schema:a");
        let shown = visible_nodes(&nodes, &collapsed, "");
        let hidden: Vec<&str> = nodes
            .iter()
            .enumerate()
            .filter(|(index, _)| !shown.contains(index))
            .map(|(_, node)| node.label.as_str())
            .collect();
        assert_eq!(hidden, vec!["Tables", "t"]);
    }

    #[test]
    fn an_empty_group_is_left_out() {
        let nodes = build_nodes(&[], &[info(None, "only_view")]);
        assert_eq!(labels(&nodes, &all(&nodes)), ["Views", "  only_view"]);
    }

    #[test]
    fn collapsing_a_group_hides_its_objects_but_keeps_the_group_to_expand_again() {
        let nodes = build_nodes(&[info(None, "users")], &[info(None, "recent")]);
        let mut collapsed = CollapseState::default();
        collapsed.toggle("schema:/tables");
        assert_eq!(
            labels(&nodes, &visible_nodes(&nodes, &collapsed, "")),
            ["Tables", "Views", "  recent"]
        );
        collapsed.toggle("schema:/tables");
        assert_eq!(visible_nodes(&nodes, &collapsed, "").len(), nodes.len());
    }

    #[test]
    fn collapsing_a_schema_hides_everything_below_it() {
        let nodes = build_nodes(&[info(Some("a"), "t1"), info(Some("b"), "t2")], &[]);
        let mut collapsed = CollapseState::default();
        collapsed.toggle("schema:a");
        assert_eq!(
            labels(&nodes, &visible_nodes(&nodes, &collapsed, "")),
            ["a", "b", "  Tables", "    t2"]
        );
    }

    #[test]
    fn a_search_shows_matches_with_their_parents_and_ignores_the_collapse_state() {
        let nodes = build_nodes(
            &[info(Some("public"), "users"), info(Some("audit"), "events")],
            &[info(Some("public"), "user_names")],
        );
        let mut collapsed = CollapseState::default();
        collapsed.toggle("schema:public");
        assert_eq!(
            labels(&nodes, &visible_nodes(&nodes, &collapsed, "user")),
            ["public", "  Tables", "    users", "  Views", "    user_names"]
        );
        assert_eq!(
            labels(&nodes, &visible_nodes(&nodes, &collapsed, "audit.ev")),
            ["audit", "  Tables", "    events"]
        );
        assert!(visible_nodes(&nodes, &collapsed, "zzz").is_empty());
    }

    #[test]
    fn the_collapse_state_round_trips_through_its_saved_keys() {
        let mut collapsed = CollapseState::default();
        collapsed.toggle("schema:b");
        collapsed.toggle("schema:a/views");
        let restored = CollapseState::from_keys(collapsed.keys());
        assert!(restored.is_collapsed("schema:b") && restored.is_collapsed("schema:a/views"));
        assert!(!restored.is_collapsed("schema:a"));
        assert_eq!(collapsed.keys(), ["schema:a/views", "schema:b"]);
    }
}
