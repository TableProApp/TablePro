use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use tablepro_storage::{
    ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionStore, ConnectionTag, SavedConnection,
    StorageError, StoragePaths,
};
use uuid::Uuid;

// A connection names its group by id, so a test that files one by name
// needs the name back to build the group.
static NAMES: LazyLock<Mutex<HashMap<Uuid, String>>> = LazyLock::new(Mutex::default);

/// The top-level group `name`, with the id a list from before group ids
/// gives it.
fn group_named(name: &str) -> ConnectionGroup {
    let group = ConnectionGroup::legacy(ConnectionGroupName::new(name).expect("a group name"));
    NAMES.lock().expect("the group names").insert(group.id, name.to_owned());
    group
}

pub(crate) fn group_id(name: &str) -> Uuid {
    group_named(name).id
}

/// The groups `connections` sit in, once each, each made by `group_id`.
pub(crate) fn groups_of(connections: &[SavedConnection]) -> Vec<ConnectionGroup> {
    let names = NAMES.lock().expect("the group names");
    let mut found: Vec<ConnectionGroup> = Vec::new();
    for id in connections.iter().filter_map(|connection| connection.group_id) {
        if found.iter().any(|group| group.id == id) {
            continue;
        }
        let name = names.get(&id).expect("a group made by group_id");
        found.push(ConnectionGroup::legacy(
            ConnectionGroupName::new(name).expect("a group name"),
        ));
    }
    found
}

/// A list of `connections` with the groups they sit in.
pub(crate) fn library(connections: Vec<SavedConnection>, tags: Vec<ConnectionTag>) -> ConnectionList {
    let groups = groups_of(&connections);
    ConnectionList::new(connections, tags).with_groups(groups)
}

/// Save `connection`, making its group first when the store lacks it.
pub(crate) fn save_filed(store: &ConnectionStore, connection: SavedConnection) {
    for group in groups_of(std::slice::from_ref(&connection)) {
        match store.create_group_blocking(group) {
            Ok(_) | Err(StorageError::GroupExists { .. }) => {}
            Err(error) => panic!("the group of {}: {error}", connection.name),
        }
    }
    store.upsert_blocking(connection).expect("the save");
}

// Through the file, since only a list from before group ids can hold two groups whose names differ only in case.
pub(crate) fn seed_library(paths: &StoragePaths, connections: &[SavedConnection]) {
    write_library(paths, connections, &groups_of(connections), &[]);
}

pub(crate) fn saved_connection(name: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "postgres".to_owned(),
        tls: tablepro_core::TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        query_timeout_secs: None,
        auth_mode: tablepro_core::AuthMode::Password,
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

// Groups nested at any depth and favourites, each item last in its place as it is added.
#[derive(Debug, Clone, Default)]
pub(crate) struct NestedLibrary {
    connections: Vec<SavedConnection>,
    groups: Vec<ConnectionGroup>,
    favourites: Vec<Uuid>,
}

impl NestedLibrary {
    pub(crate) fn group(&mut self, name: &str, parent: Option<Uuid>) -> Uuid {
        let order = self.groups.iter().filter(|group| group.parent_id == parent).count();
        let group = ConnectionGroup {
            order: u32::try_from(order).expect("a small library"),
            ..ConnectionGroup::new(ConnectionGroupName::new(name).expect("a group name"), parent)
        };
        let id = group.id;
        self.groups.push(group);
        id
    }

    pub(crate) fn connection(&mut self, name: &str, group: Option<Uuid>) -> Uuid {
        self.add(SavedConnection {
            group_id: group,
            ..saved_connection(name)
        })
    }

    // Keeps the connection's group and puts it last there.
    pub(crate) fn add(&mut self, connection: SavedConnection) -> Uuid {
        let order = self
            .connections
            .iter()
            .filter(|held| held.group_id == connection.group_id)
            .count();
        let id = connection.id;
        self.connections.push(SavedConnection {
            order: u32::try_from(order).expect("a small library"),
            ..connection
        });
        id
    }

    pub(crate) fn favourite(&mut self, id: Uuid) {
        self.favourites.push(id);
    }

    pub(crate) fn list(&self) -> ConnectionList {
        ConnectionList::new(self.connections.clone(), Vec::new())
            .with_groups(self.groups.clone())
            .with_favorites(self.favourites.clone())
    }

    pub(crate) fn seed(&self, paths: &StoragePaths) {
        write_library(paths, &self.connections, &self.groups, &self.favourites);
    }
}

fn write_library(
    paths: &StoragePaths,
    connections: &[SavedConnection],
    groups: &[ConnectionGroup],
    favorites: &[Uuid],
) {
    #[derive(serde::Serialize)]
    struct Library<'a> {
        version: u32,
        connections: &'a [SavedConnection],
        groups: &'a [ConnectionGroup],
        favorites: &'a [Uuid],
    }

    let document = Library {
        version: 3,
        connections,
        groups,
        favorites,
    };
    let file = paths.connections_file();
    std::fs::create_dir_all(file.parent().expect("the file's folder")).expect("the folder");
    std::fs::write(&file, serde_json::to_vec(&document).expect("the document")).expect("the file");
}
