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
pub(crate) fn group_named(name: &str) -> ConnectionGroup {
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

/// Write `connections` and their groups as the file a store under
/// `paths` reads first, for groups whose names differ only in case,
/// which only a list from before group ids can hold.
pub(crate) fn seed_library(paths: &StoragePaths, connections: &[SavedConnection]) {
    #[derive(serde::Serialize)]
    struct Library<'a> {
        version: u32,
        connections: &'a [SavedConnection],
        groups: Vec<ConnectionGroup>,
    }

    let document = Library {
        version: 3,
        connections,
        groups: groups_of(connections),
    };
    let file = paths.connections_file();
    std::fs::create_dir_all(file.parent().expect("the file's folder")).expect("the folder");
    std::fs::write(&file, serde_json::to_vec(&document).expect("the document")).expect("the file");
}
