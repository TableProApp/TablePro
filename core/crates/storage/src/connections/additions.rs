use std::collections::HashMap;

use uuid::Uuid;

use super::{ConnectionList, ConnectionStore, ConnectionsDocument, SavedConnection, unclaimed_name};
use crate::error::StorageError;
use crate::{ConnectionGroup, ConnectionGroupName};

// A connection an import brings from somewhere other than an exported list, such as another app.
#[derive(Debug, Clone)]
pub struct ImportedConnection {
    pub connection: SavedConnection,
    // Matched in any case in its place and made where missing; names past MAX_DEPTH are dropped.
    pub group_path: Vec<ConnectionGroupName>,
    pub replaces: Option<Uuid>,
}

impl ConnectionStore {
    // The list the user reviewed must still be the list, since a duplicate found then may be gone.
    // A replacement keeps the saved id only when it connects alike, as the keyring files secrets by id.
    pub fn add_imported_blocking(
        &self,
        expected: &ConnectionList,
        imported: Vec<ImportedConnection>,
    ) -> Result<Vec<SavedConnection>, StorageError> {
        let mut state = self.lock_to_write();
        let mut document = self.ensure_current(&mut state)?;
        if !document.lists_as(expected) {
            return Err(StorageError::ImportOutdated);
        }
        let held: HashMap<String, Uuid> = document
            .connections
            .iter()
            .map(|saved| (saved.name.clone(), saved.id))
            .collect();
        let mut saved = Vec::with_capacity(imported.len());
        for entry in imported {
            let group_id = document.ensure_group_path(&entry.group_path);
            let mut connection = entry.connection;
            connection.group_id = group_id;
            connection.last_opened_at = None;
            let target = entry.replaces.and_then(|id| {
                document.connections.iter().position(|existing| {
                    existing.id == id
                        && existing.connects_like(&SavedConnection {
                            id,
                            ..connection.clone()
                        })
                })
            });
            match target {
                Some(index) => {
                    let existing = &document.connections[index];
                    connection.id = existing.id;
                    connection.order = if existing.group_id == connection.group_id {
                        existing.order
                    } else {
                        document.next_connection_order(connection.group_id)
                    };
                    connection.keep_marks_from(existing);
                    connection.name =
                        unclaimed_name(&document.connections, &held, &connection.name, Some(connection.id));
                    document.connections[index] = connection.clone();
                }
                None => {
                    connection.id = Uuid::new_v4();
                    connection.order = document.next_connection_order(connection.group_id);
                    connection.name = unclaimed_name(&document.connections, &held, &connection.name, None);
                    document.connections.push(connection.clone());
                }
            }
            saved.push(connection);
        }
        if saved.is_empty() {
            return Ok(saved);
        }
        self.commit(&mut state, document)?;
        Ok(saved)
    }
}

impl SavedConnection {
    // Marks only this app sets, which the other app never had.
    fn keep_marks_from(&mut self, existing: &SavedConnection) {
        self.tags.clone_from(&existing.tags);
        self.icon = existing.icon;
        self.last_opened_at = existing.last_opened_at;
    }
}

impl ConnectionsDocument {
    fn lists_as(&self, list: &ConnectionList) -> bool {
        self.connections.as_slice() == &*list.connections
            && self.groups.as_slice() == &*list.groups
            && self.tags.as_slice() == &*list.tags
            && self.favorites.as_slice() == &*list.favorites
    }

    fn ensure_group_path(&mut self, path: &[ConnectionGroupName]) -> Option<Uuid> {
        let mut parent = None;
        for name in path.iter().take(ConnectionGroup::MAX_DEPTH) {
            let group = match self.group_named(parent, name) {
                Some(group) => group,
                None => {
                    let group = ConnectionGroup {
                        order: self.next_group_order(parent),
                        ..ConnectionGroup::new(name.clone(), parent)
                    };
                    self.groups.push(group.clone());
                    group
                }
            };
            parent = Some(group.id);
        }
        parent
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{SafeModeLevel, TlsConfig};

    use super::*;
    use crate::{ConnectionColor, StoragePaths};

    fn store() -> (tempfile::TempDir, ConnectionStore) {
        let dir = tempfile::tempdir().expect("a temp dir");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro"));
        (dir, store)
    }

    fn connection(name: &str, host: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: host.to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "admin".to_owned(),
            tls: TlsConfig::disabled(),
            safe_mode: SafeModeLevel::Off,
            external_access: Default::default(),
            ai_policy: Default::default(),
            query_timeout_secs: None,
            masking_rules: Vec::new(),
            auth_mode: Default::default(),
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn name(value: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(value).expect("a group name")
    }

    fn list(store: &ConnectionStore) -> ConnectionList {
        store.list_blocking().expect("the list")
    }

    fn add(store: &ConnectionStore, imported: Vec<ImportedConnection>) -> Vec<SavedConnection> {
        let before = list(store);
        store.add_imported_blocking(&before, imported).expect("the import")
    }

    fn added(connection: SavedConnection, path: &[&str]) -> ImportedConnection {
        ImportedConnection {
            connection,
            group_path: path.iter().map(|part| name(part)).collect(),
            replaces: None,
        }
    }

    #[test]
    fn added_entries_get_new_ids_and_land_in_their_groups_made_once() {
        let (_dir, store) = store();
        let saved = add(
            &store,
            vec![
                added(connection("a", "one"), &["Work", "Staging"]),
                added(connection("b", "two"), &["work", "Staging"]),
            ],
        );
        let after = list(&store);
        assert_eq!(after.groups.len(), 2);
        assert_eq!(saved[0].group_id, saved[1].group_id);
        let tree = after.group_tree();
        let leaf = saved[0].group_id.expect("a group");
        assert_eq!(tree.label(leaf).as_deref(), Some("Work / Staging"));
        assert_eq!((saved[0].order, saved[1].order), (0, 1));
    }

    #[test]
    fn a_group_path_past_the_depth_limit_is_cut() {
        let (_dir, store) = store();
        let saved = add(&store, vec![added(connection("a", "one"), &["1", "2", "3", "4"])]);
        let after = list(&store);
        assert_eq!(after.groups.len(), ConnectionGroup::MAX_DEPTH);
        let leaf = saved[0].group_id.expect("a group");
        assert_eq!(after.group_tree().label(leaf).as_deref(), Some("1 / 2 / 3"));
    }

    #[test]
    fn an_added_entry_never_takes_a_held_name() {
        let (_dir, store) = store();
        let held = connection("prod", "one");
        store.upsert_blocking(held).expect("a save");
        let saved = add(&store, vec![added(connection("prod", "elsewhere"), &[])]);
        assert_eq!(saved[0].name, "prod (imported)");
    }

    #[test]
    fn a_replacement_keeps_the_id_only_when_it_connects_alike() {
        let (_dir, store) = store();
        let mut held = connection("prod", "one");
        held.tags = Vec::new();
        held.color = Some(ConnectionColor::Red);
        store.upsert_blocking(held.clone()).expect("a save");

        let mut alike = connection("Production", "one");
        alike.color = Some(ConnectionColor::Blue);
        let mut elsewhere = connection("prod copy", "another-host");
        elsewhere.id = held.id;
        let saved = add(
            &store,
            vec![
                ImportedConnection {
                    connection: alike,
                    group_path: Vec::new(),
                    replaces: Some(held.id),
                },
                ImportedConnection {
                    connection: elsewhere,
                    group_path: Vec::new(),
                    replaces: Some(held.id),
                },
            ],
        );
        assert_eq!(saved[0].id, held.id);
        assert_eq!(saved[0].name, "Production");
        assert_eq!(saved[0].color, Some(ConnectionColor::Blue));
        assert_ne!(saved[1].id, held.id);
        assert_eq!(list(&store).connections.len(), 2);
    }

    #[test]
    fn a_list_changed_since_the_review_is_refused() {
        let (_dir, store) = store();
        let before = list(&store);
        store.upsert_blocking(connection("meanwhile", "one")).expect("a save");
        let refused = store.add_imported_blocking(&before, vec![added(connection("a", "two"), &[])]);
        assert!(matches!(refused, Err(StorageError::ImportOutdated)));
    }
}
