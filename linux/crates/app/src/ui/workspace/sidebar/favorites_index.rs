use std::collections::{HashMap, HashSet};

use tablepro_storage::saved_queries::{SavedQueriesSnapshot, SavedQuery, SavedQueryFolder};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum Key {
    Folder(Uuid),
    Query(Uuid),
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
        let id = Uuid::parse_str(id).ok()?;
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

    pub(super) fn parent(&self) -> Option<Uuid> {
        match self {
            Self::Folder(folder) => folder.parent_id,
            Self::Query(query) => query.folder_id,
        }
    }

    fn order(&self) -> (u8, i64, String, Uuid) {
        match self {
            Self::Folder(folder) => (0, folder.order, folder.name.to_lowercase(), folder.id),
            Self::Query(query) => (1, query.order, query.name.to_lowercase(), query.id),
        }
    }
}

#[derive(Default)]
pub(super) struct Index {
    pub(super) nodes: HashMap<Key, Node>,
    children: HashMap<Option<Uuid>, Vec<Key>>,
    paths: HashMap<Uuid, String>,
}

impl Index {
    pub(super) fn new(snapshot: SavedQueriesSnapshot) -> Option<Self> {
        let mut index = Self::default();
        let mut owners = HashSet::new();
        // A reference nothing here answers to reads as the top level (core ADR 0052).
        let folders: HashSet<Uuid> = snapshot.folders.iter().map(|folder| folder.id).collect();
        for node in snapshot
            .folders
            .into_iter()
            .map(Node::Folder)
            .chain(snapshot.queries.into_iter().map(Node::Query))
        {
            // What has no connection shows in every connection's snapshot beside that connection's own.
            owners.extend(match &node {
                Node::Folder(folder) => folder.connection_id,
                Node::Query(query) => query.connection_id,
            });
            let parent = node.parent().filter(|parent| folders.contains(parent));
            index.children.entry(parent).or_default().push(node.key());
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

    pub(super) fn children(&self, parent: Option<Uuid>) -> &[Key] {
        self.children.get(&parent).map_or(&[], Vec::as_slice)
    }

    pub(super) fn path(&self, id: Uuid) -> Option<&str> {
        self.paths.get(&id).map(String::as_str)
    }

    pub(super) fn destinations(&self) -> Vec<(Uuid, String)> {
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

    fn id(number: u128) -> Uuid {
        Uuid::from_u128(number)
    }

    fn folder(number: u128, name: &str, parent: Option<u128>) -> SavedQueryFolder {
        SavedQueryFolder {
            id: id(number),
            name: name.to_owned(),
            parent_id: parent.map(id),
            connection_id: Some(Uuid::nil()),
            order: 0,
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    fn query(number: u128, name: &str, folder: Option<u128>, connection: Option<Uuid>) -> SavedQuery {
        SavedQuery {
            id: id(number),
            name: name.to_owned(),
            query: "SELECT 1".to_owned(),
            connection_id: connection,
            connection_name: String::new(),
            keyword: None,
            folder_id: folder.map(id),
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
                (id(7), "/a\\\\\\/b".to_owned()),
                (id(3), "/Archive".to_owned()),
                (id(4), "/Archive/Monthly".to_owned()),
                (id(6), "/No Folder".to_owned()),
                (id(1), "/Reports".to_owned()),
                (id(2), "/Reports/Monthly".to_owned()),
                (id(5), "/Reports\\/Monthly".to_owned()),
            ]
        );
    }

    #[test]
    fn malformed_hierarchies_are_refused_instead_of_hiding_queries_or_recursing() {
        for folders in [
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

    // A pull can bring a record before the folder it names (core ADR 0052, References).
    #[test]
    fn a_parent_or_folder_the_snapshot_lacks_reads_as_the_top_level() {
        let index = Index::new(SavedQueriesSnapshot {
            queries: vec![query(10, "Lost", Some(99), Some(Uuid::nil()))],
            folders: vec![folder(1, "Orphan", Some(98))],
        })
        .expect("index");

        assert_eq!(index.children(None), [Key::Folder(id(1)), Key::Query(id(10))]);
        assert_eq!(index.path(id(1)), Some("/Orphan"));
    }

    #[test]
    fn a_query_with_no_connection_sits_beside_the_connections_own() {
        let index = Index::new(SavedQueriesSnapshot {
            queries: vec![
                query(10, "Everywhere", None, None),
                query(11, "Mine", None, Some(Uuid::nil())),
            ],
            folders: vec![],
        })
        .expect("index");
        assert_eq!(index.children(None).len(), 2);

        let mixed = Index::new(SavedQueriesSnapshot {
            queries: vec![
                query(10, "Mine", None, Some(Uuid::nil())),
                query(11, "Theirs", None, Some(Uuid::max())),
            ],
            folders: vec![],
        });
        assert!(mixed.is_none(), "two connections' records in one snapshot");
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
        assert_eq!(index.children(None), [Key::Folder(id(8)), Key::Folder(id(3))]);
        assert_ne!(Key::Folder(id(3)), Key::Query(id(3)));
        for key in [Key::Folder(id(3)), Key::Query(id(3))] {
            assert_eq!(Key::parse(&key.target()), Some(key));
        }
        for text in ["", "😀", "qabc", "x3", "q3"] {
            assert_eq!(Key::parse(text), None);
        }
    }
}
