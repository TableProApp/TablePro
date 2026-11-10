use std::collections::{HashMap, HashSet};

use tablepro_storage::saved_queries::{SavedQueriesSnapshot, SavedQuery, SavedQueryFolder};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum Key {
    Folder(i64),
    Query(i64),
}

impl Key {
    pub(super) fn target(self) -> String {
        match self {
            Self::Folder(id) => format!("f{id}"),
            Self::Query(id) => format!("q{id}"),
        }
    }

    pub(super) fn parse(target: &str) -> Option<Self> {
        let (kind, id) = target.split_at_checked(1)?;
        let id = id.parse().ok()?;
        match kind {
            "f" => Some(Self::Folder(id)),
            "q" => Some(Self::Query(id)),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub(super) enum Node {
    Folder(SavedQueryFolder),
    Query(SavedQuery),
}

impl Node {
    pub(super) fn key(&self) -> Key {
        match self {
            Self::Folder(folder) => Key::Folder(folder.id),
            Self::Query(query) => Key::Query(query.id),
        }
    }

    pub(super) fn name(&self) -> &str {
        match self {
            Self::Folder(folder) => &folder.name,
            Self::Query(query) => &query.name,
        }
    }

    pub(super) fn parent(&self) -> Option<i64> {
        match self {
            Self::Folder(folder) => folder.parent_id,
            Self::Query(query) => query.folder_id,
        }
    }

    fn order(&self) -> (u8, i64, String, i64) {
        match self {
            Self::Folder(folder) => (0, folder.order, folder.name.to_lowercase(), folder.id),
            Self::Query(query) => (1, query.order, query.name.to_lowercase(), query.id),
        }
    }
}

#[derive(Default)]
pub(super) struct Index {
    pub(super) nodes: HashMap<Key, Node>,
    children: HashMap<Option<i64>, Vec<Key>>,
    paths: HashMap<i64, String>,
}

impl Index {
    pub(super) fn new(snapshot: SavedQueriesSnapshot) -> Option<Self> {
        let mut index = Self::default();
        let mut owners = HashSet::new();
        for node in snapshot
            .folders
            .into_iter()
            .map(Node::Folder)
            .chain(snapshot.queries.into_iter().map(Node::Query))
        {
            owners.insert(match &node {
                Node::Folder(folder) => folder.connection_id,
                Node::Query(query) => query.connection_id,
            });
            index.children.entry(node.parent()).or_default().push(node.key());
            if index.nodes.insert(node.key(), node).is_some() {
                return None;
            }
        }
        if owners.len() > 1 {
            return None;
        }
        for keys in index.children.values_mut() {
            keys.sort_by_cached_key(|key| index.nodes[key].order());
        }
        let mut pending = vec![(None, String::new())];
        let mut visited = HashSet::new();
        while let Some((parent, path)) = pending.pop() {
            for key in index.children.get(&parent).into_iter().flatten() {
                if !visited.insert(*key) {
                    return None;
                }
                if let Key::Folder(id) = key {
                    let name = index.nodes[key].name().replace('\\', "\\\\").replace('/', "\\/");
                    let path = format!("{path}/{name}");
                    index.paths.insert(*id, path.clone());
                    pending.push((Some(*id), path));
                }
            }
        }
        (visited.len() == index.nodes.len()).then_some(index)
    }

    pub(super) fn children(&self, parent: Option<i64>) -> &[Key] {
        self.children.get(&parent).map_or(&[], Vec::as_slice)
    }

    pub(super) fn path(&self, id: i64) -> Option<&str> {
        self.paths.get(&id).map(String::as_str)
    }

    pub(super) fn destinations(&self) -> Vec<(i64, String)> {
        let mut folders: Vec<_> = self.paths.iter().map(|(id, path)| (*id, path.clone())).collect();
        folders.sort_by_cached_key(|(id, path)| (path.to_lowercase(), path.clone(), *id));
        folders
    }

    #[cfg(test)]
    pub(super) fn queries(&self) -> Vec<SavedQuery> {
        let mut queries: Vec<_> = self
            .nodes
            .values()
            .filter_map(|node| match node {
                Node::Query(query) => Some(query.clone()),
                Node::Folder(_) => None,
            })
            .collect();
        queries.sort_by_key(|query| (query.folder_id, query.order, query.name.to_lowercase(), query.id));
        queries
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;
    use uuid::Uuid;

    fn folder(id: i64, name: &str, parent_id: Option<i64>) -> SavedQueryFolder {
        SavedQueryFolder {
            id,
            name: name.to_owned(),
            parent_id,
            connection_id: Uuid::nil(),
            order: 0,
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    #[test]
    fn folder_destinations_distinguish_ancestry_separators_and_the_root_label() {
        let index = Index::new(SavedQueriesSnapshot {
            queries: vec![],
            folders: vec![
                folder(1, "Reports", None),
                folder(2, "Monthly", Some(1)),
                folder(3, "Archive", None),
                folder(4, "Monthly", Some(3)),
                folder(5, "Reports/Monthly", None),
                folder(6, "No Folder", None),
                folder(7, "a\\/b", None),
            ],
        })
        .expect("valid hierarchy");
        assert_eq!(
            index.destinations(),
            vec![
                (7, "/a\\\\\\/b".to_owned()),
                (3, "/Archive".to_owned()),
                (4, "/Archive/Monthly".to_owned()),
                (6, "/No Folder".to_owned()),
                (1, "/Reports".to_owned()),
                (2, "/Reports/Monthly".to_owned()),
                (5, "/Reports\\/Monthly".to_owned()),
            ]
        );
    }

    #[test]
    fn malformed_hierarchies_are_refused_instead_of_hiding_queries_or_recursing() {
        for folders in [
            vec![folder(1, "Orphan", Some(99))],
            vec![folder(1, "Cycle", Some(2)), folder(2, "Cycle", Some(1))],
            vec![folder(1, "Duplicate", None), folder(1, "Duplicate", None)],
        ] {
            assert!(
                Index::new(SavedQueriesSnapshot {
                    queries: vec![],
                    folders
                })
                .is_none()
            );
        }
    }

    #[test]
    fn typed_keys_and_sibling_order_are_stable() {
        let mut first = folder(8, "Z", None);
        first.order = 0;
        let mut second = folder(3, "A", None);
        second.order = 1;
        let index = Index::new(SavedQueriesSnapshot {
            queries: vec![],
            folders: vec![second, first],
        })
        .expect("index");
        assert_eq!(index.children(None), [Key::Folder(8), Key::Folder(3)]);
        assert_ne!(Key::Folder(3), Key::Query(3));
        for key in [Key::Folder(3), Key::Query(3)] {
            assert_eq!(Key::parse(&key.target()), Some(key));
        }
        for text in ["", "😀", "qabc", "x3"] {
            assert_eq!(Key::parse(text), None);
        }
    }
}
