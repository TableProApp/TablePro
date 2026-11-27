use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, LazyLock, Mutex};

use tablepro_storage::{
    ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionListState, ConnectionProject,
    ConnectionProjectName, ConnectionStore, ConnectionTag, SavedConnection, StorageError, StoragePaths,
};
use uuid::Uuid;

use crate::services::saved_connection_list::SavedConnectionList;

// A connection names its group by id, so a test that files one by name
// needs the name back to build the group.
static NAMES: LazyLock<Mutex<HashMap<Uuid, String>>> = LazyLock::new(Mutex::default);

/// The top-level group `name`, with the same id every time it is named.
fn group_named(name: &str) -> ConnectionGroup {
    let mut names = NAMES.lock().expect("the group names");
    let id = names
        .iter()
        .find_map(|(id, held)| (held == name).then_some(*id))
        .unwrap_or_else(Uuid::new_v4);
    names.insert(id, name.to_owned());
    top_level(id, name)
}

fn top_level(id: Uuid, name: &str) -> ConnectionGroup {
    ConnectionGroup {
        id,
        ..ConnectionGroup::new(ConnectionGroupName::new(name).expect("a group name"), None)
    }
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
        found.push(top_level(id, name));
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

// Through the file, since the store refuses two groups whose names differ only in case and a file can hold them.
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
        safe_mode: tablepro_core::SafeModeLevel::Silent,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        query_timeout_secs: None,
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        project_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
        details: Default::default(),
        device: Default::default(),
        unknown: Default::default(),
    }
}

// A list over a store nothing writes to, so the library a test applies stands.
pub(crate) fn detached_list(root: &std::path::Path) -> Rc<SavedConnectionList> {
    let paths = StoragePaths::under(&root.join("detached"), "tablepro", crate::config::APP_ID);
    SavedConnectionList::follow(
        &ConnectionStore::new(&paths),
        Arc::new(tablepro_core::DriverRegistry::new()),
    )
}

pub(crate) fn project_named(name: &str) -> ConnectionProject {
    ConnectionProject::new(ConnectionProjectName::new(name).expect("a project name"))
}

// The library a store would publish with each project holding the connections of these ids.
pub(crate) fn show_projects(list: &SavedConnectionList, projects: &[(&ConnectionProject, &[Uuid])]) {
    let connections: Vec<SavedConnection> = projects
        .iter()
        .flat_map(|(project, ids)| {
            ids.iter().map(|id| SavedConnection {
                id: *id,
                project_id: Some(project.id),
                ..saved_connection(&id.to_string())
            })
        })
        .collect();
    let projects: Vec<ConnectionProject> = projects
        .iter()
        .zip(0..)
        .map(|((project, _), order)| ConnectionProject {
            order,
            ..(*project).clone()
        })
        .collect();
    list.apply(ConnectionListState::Ready(
        ConnectionList::new(connections, Vec::new()).with_projects(projects),
    ));
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
        version: 1,
        connections,
        groups,
        favorites,
    };
    let file = paths.connections_file();
    std::fs::create_dir_all(file.parent().expect("the file's folder")).expect("the folder");
    std::fs::write(&file, serde_json::to_vec(&document).expect("the document")).expect("the file");
}
