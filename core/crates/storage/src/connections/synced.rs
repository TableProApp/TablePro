use uuid::Uuid;

use super::{ConnectionList, ConnectionStore, ConnectionsDocument, CredentialProfile, SavedConnection, SshProfile};
use crate::error::StorageError;
use crate::store_identity::StoreIdentity;
use crate::{ConnectionGroup, ConnectionTag};

// One record a sync pull settled (core ADR 0054, Adapters). Values go in as given, places and links included, since a
// pull can bring a connection before its group, tag or profile, and its siblings' places with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryChange {
    Connection {
        connection: Box<SavedConnection>,
        favorite: bool,
    },
    ConnectionGone(Uuid),
    Group(ConnectionGroup),
    GroupGone(Uuid),
    Tag(ConnectionTag),
    TagGone(Uuid),
    SshProfile(SshProfile),
    SshProfileGone(Uuid),
    CredentialProfile(CredentialProfile),
    CredentialProfileGone(Uuid),
}

// The library as sync reads it: the list, with the ids of each profile kind this build cannot read.
#[derive(Debug, Clone)]
pub struct SyncedLibrary {
    pub list: ConnectionList,
    pub unreadable_ssh_profiles: Vec<Uuid>,
    pub unreadable_credential_profiles: Vec<Uuid>,
}

impl ConnectionStore {
    pub fn synced_library_blocking(&self) -> Result<SyncedLibrary, StorageError> {
        let mut state = self.lock();
        let document = self.ensure_loaded(&mut state)?;
        Ok(SyncedLibrary {
            list: document.list(),
            unreadable_ssh_profiles: document.ssh_profiles.held_ids(),
            unreadable_credential_profiles: document.credential_profiles.held_ids(),
        })
    }

    // The changes `settle` makes of the list as it is under the write lock, in one write, so what it keeps of the
    // stored records is what the write replaces. A connection the list holds keeps what this device alone holds,
    // except the two marks sync itself settles. Returns the file's identity after the write.
    pub fn apply_synced_blocking(
        &self,
        settle: impl FnOnce(&ConnectionList) -> Vec<LibraryChange>,
    ) -> Result<Option<StoreIdentity>, StorageError> {
        let mut state = self.lock_to_write();
        let before = self.ensure_current(&mut state)?;
        let mut document = before.clone();
        for change in settle(&before.list()) {
            document.apply_synced(change);
        }
        document.keep_membership_of_released(&before);
        document.tidy();
        if document != before {
            self.commit(&mut state, document)?;
        }
        match &*state {
            super::StoreState::Ready(document, _) => Ok(document.store),
            super::StoreState::Unloaded | super::StoreState::Unavailable(..) => Ok(None),
        }
    }
}

impl ConnectionsDocument {
    fn apply_synced(&mut self, change: LibraryChange) {
        match change {
            LibraryChange::Connection { connection, favorite } => self.put_synced(*connection, favorite),
            LibraryChange::ConnectionGone(id) => {
                self.connections.remove_id(id);
                self.favorites.retain(|held| *held != id);
            }
            LibraryChange::Group(group) => put_by_id(&mut self.groups, group, |group| group.id),
            // As the device that deleted it did, what the group held moves to the top; `keep_membership_of_released`
            // then keeps it in the group's project.
            LibraryChange::GroupGone(id) => {
                self.groups.retain(|group| group.id != id);
                for group in &mut self.groups {
                    if group.parent_id == Some(id) {
                        group.parent_id = None;
                    }
                }
                for connection in self.connections.iter_mut() {
                    if connection.group_id == Some(id) {
                        connection.group_id = None;
                    }
                }
            }
            LibraryChange::Tag(tag) => put_by_id(&mut self.tags, tag, |tag| tag.id),
            LibraryChange::TagGone(id) => self.tags.retain(|tag| tag.id != id),
            LibraryChange::SshProfile(profile) => {
                self.ssh_profiles.release(profile.id);
                put_by_id(&mut self.ssh_profiles, profile, |profile| profile.id);
            }
            LibraryChange::SshProfileGone(id) => {
                self.ssh_profiles.remove_id(id);
            }
            LibraryChange::CredentialProfile(profile) => {
                self.credential_profiles.release(profile.id);
                put_by_id(&mut self.credential_profiles, profile, |profile| profile.id);
            }
            LibraryChange::CredentialProfileGone(id) => {
                self.credential_profiles.remove_id(id);
            }
        }
    }

    fn put_synced(&mut self, mut connection: SavedConnection, favorite: bool) {
        let id = connection.id;
        if let Some(stored) = self.connections.iter().find(|saved| saved.id == id) {
            let marks = (
                connection.device.tls_mode_unsettled,
                connection.device.ssh_profile_unlinked,
            );
            connection.device = stored.device.clone();
            (
                connection.device.tls_mode_unsettled,
                connection.device.ssh_profile_unlinked,
            ) = marks;
            connection.last_opened_at = stored.last_opened_at;
        }
        self.connections.release(id);
        match self.connections.iter_mut().find(|saved| saved.id == id) {
            Some(slot) => *slot = connection,
            None => self.connections.push(connection),
        }
        let listed = self.favorites.contains(&id);
        if favorite && !listed {
            self.favorites.push(id);
        } else if !favorite && listed {
            self.favorites.retain(|held| *held != id);
        }
    }
}

fn put_by_id<T>(list: &mut Vec<T>, entry: T, id: impl Fn(&T) -> Uuid) {
    let key = id(&entry);
    match list.iter_mut().find(|held| id(held) == key) {
        Some(slot) => *slot = entry,
        None => list.push(entry),
    }
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]
mod tests {
    use chrono::Utc;
    use serde_json::json;
    use tablepro_core::{AiPolicy, ExternalAccess, NetworkOptions, SafeModeLevel, TlsConfig};

    use super::*;
    use crate::connections::{ConnectionDetails, DeviceOnly};
    use crate::{ConnectionColor, ConnectionGroupName, ConnectionTagName, StoragePaths};

    fn store(dir: &std::path::Path) -> ConnectionStore {
        ConnectionStore::new(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
    }

    fn saved(id: u128, name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::from_u128(id),
            name: name.to_owned(),
            driver_id: "PostgreSQL".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: String::new(),
            username: String::new(),
            tls: TlsConfig::disabled(),
            safe_mode: SafeModeLevel::Silent,
            external_access: ExternalAccess::default(),
            ai_policy: AiPolicy::default(),
            query_timeout_secs: None,
            auth_mode: Default::default(),
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            project_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: NetworkOptions::default(),
            details: ConnectionDetails::default(),
            device: DeviceOnly::default(),
            unknown: Default::default(),
        }
    }

    #[test]
    fn a_pulled_connection_keeps_this_device_s_own_fields_and_its_place_and_links_as_given() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let mut local = saved(1, "prod");
        local.device.local_only = true;
        local.device.tls_mode_unsettled = true;
        local.last_opened_at = Some(Utc::now());
        store.upsert_blocking(local.clone()).unwrap();
        let missing_group = Uuid::from_u128(77);
        let mut pulled = saved(1, "prod 2");
        pulled.group_id = Some(missing_group);
        pulled.order = 9;
        pulled.tags = vec![Uuid::from_u128(88)];

        let identity = store
            .apply_synced_blocking(|_| {
                vec![LibraryChange::Connection {
                    connection: Box::new(pulled),
                    favorite: true,
                }]
            })
            .unwrap();
        let list = store.list_blocking().unwrap();

        let held = &list.connections[0];
        assert_eq!(held.name, "prod 2");
        assert_eq!(held.group_id, Some(missing_group));
        assert_eq!(held.order, 9);
        assert_eq!(held.tags, vec![Uuid::from_u128(88)]);
        assert!(held.device.local_only);
        assert!(!held.device.tls_mode_unsettled);
        assert_eq!(held.last_opened_at, local.last_opened_at);
        assert!(list.is_favorite(local.id));
        assert_eq!(identity, list.store);
    }

    #[test]
    fn one_write_puts_and_removes_every_kind_and_a_removal_takes_the_favourite_mark() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        store.upsert_blocking(saved(1, "a")).unwrap();
        store.upsert_blocking(saved(2, "b")).unwrap();
        store.add_favorites_blocking(&[Uuid::from_u128(2)], None).unwrap();
        let group = ConnectionGroup::new(ConnectionGroupName::new("Work").unwrap(), None);
        let tag = ConnectionTag::new(ConnectionTagName::new("prod").unwrap(), ConnectionColor::Red);
        let profile: SshProfile = serde_json::from_value(json!({
            "id": Uuid::from_u128(5), "name": "bastion", "host": "edge", "auth": {"kind": "agent"},
        }))
        .unwrap();

        store
            .apply_synced_blocking(|_| {
                vec![
                    LibraryChange::ConnectionGone(Uuid::from_u128(2)),
                    LibraryChange::Group(group.clone()),
                    LibraryChange::Tag(tag.clone()),
                    LibraryChange::SshProfile(profile.clone()),
                ]
            })
            .unwrap();
        let list = store.list_blocking().unwrap();
        assert_eq!(list.connections.len(), 1);
        assert!(list.favorites.is_empty());
        assert_eq!(list.groups.as_ref(), std::slice::from_ref(&group));
        assert_eq!(list.tags.as_ref(), std::slice::from_ref(&tag));
        assert_eq!(list.ssh_profiles.as_ref(), std::slice::from_ref(&profile));

        store
            .apply_synced_blocking(|_| {
                vec![
                    LibraryChange::GroupGone(group.id),
                    LibraryChange::TagGone(tag.id),
                    LibraryChange::SshProfileGone(profile.id),
                ]
            })
            .unwrap();
        let list = store.list_blocking().unwrap();
        assert!(list.groups.is_empty() && list.tags.is_empty() && list.ssh_profiles.is_empty());
    }

    #[test]
    fn a_pulled_group_deletion_moves_what_it_held_to_the_top_in_its_project() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let acme = store
            .create_project_blocking(crate::ConnectionProject::new(
                crate::ConnectionProjectName::new("Acme").unwrap(),
            ))
            .unwrap();
        let mut work = ConnectionGroup::new(ConnectionGroupName::new("Work").unwrap(), None);
        work.project_id = Some(acme.id);
        let work = store.create_group_blocking(work).unwrap();
        let europe = store
            .create_group_blocking(ConnectionGroup::new(
                ConnectionGroupName::new("Europe").unwrap(),
                Some(work.id),
            ))
            .unwrap();
        let mut member = saved(1, "prod");
        member.group_id = Some(work.id);
        member.device.local_only = true;
        store.upsert_blocking(member.clone()).unwrap();

        store
            .apply_synced_blocking(|_| vec![LibraryChange::GroupGone(work.id)])
            .unwrap();
        let list = store.list_blocking().unwrap();

        let held = &list.connections[0];
        assert_eq!(held.group_id, None);
        assert_eq!(list.effective_project(held), Some(acme.id));
        let kept = list.groups.iter().find(|group| group.id == europe.id).unwrap();
        assert_eq!(kept.parent_id, None);
        assert_eq!(list.effective_group_project(europe.id), Some(acme.id));
    }

    #[test]
    fn a_readable_copy_takes_the_place_of_one_this_build_could_not_read() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let mut held = serde_json::to_value(saved(3, "future")).unwrap();
        held["safe_mode"] = json!("someday");
        std::fs::create_dir_all(store.path().parent().unwrap()).unwrap();
        std::fs::write(
            store.path(),
            serde_json::to_vec(&json!({"version": 1, "connections": [held]})).unwrap(),
        )
        .unwrap();
        assert_eq!(store.list_blocking().unwrap().unreadable.as_ref(), [Uuid::from_u128(3)]);

        store
            .apply_synced_blocking(|_| {
                vec![LibraryChange::Connection {
                    connection: Box::new(saved(3, "future")),
                    favorite: false,
                }]
            })
            .unwrap();

        let list = store.list_blocking().unwrap();
        assert!(list.unreadable.is_empty());
        assert_eq!(list.connections.len(), 1);
    }

    #[test]
    fn a_write_that_changes_nothing_leaves_the_file_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        store.upsert_blocking(saved(1, "a")).unwrap();
        let before = store.identity_blocking().unwrap();
        let held = store.list_blocking().unwrap().connections[0].clone();

        let after = store
            .apply_synced_blocking(|_| {
                vec![LibraryChange::Connection {
                    connection: Box::new(held),
                    favorite: false,
                }]
            })
            .unwrap();

        assert_eq!(after, before);
    }
}
