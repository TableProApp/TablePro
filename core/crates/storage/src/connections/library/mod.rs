use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::SystemTime;

use uuid::Uuid;

use super::placement::{placed, unique};
use super::write_guard::WriteGuard;
use super::{
    ConnectionList, ConnectionStore, ConnectionsDocument, CredentialProfile, RemoveOutcome, Reported, SavedConnection,
    SecretOwner, SecretOwnerKind, SshProfile, StoreState,
};
use crate::error::StorageError;
use crate::lenient::{Identified, Lenient};
use crate::store_identity::StoreIdentity;
use crate::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionProject, ConnectionTag, GroupTree, LibraryIcon,
};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LibraryWrite {
    pub connections: Vec<SavedConnection>,
    pub groups: Vec<ConnectionGroup>,
    pub tags: Vec<ConnectionTag>,
    pub favorites: Vec<Uuid>,
    pub projects: Vec<ConnectionProject>,
    pub ssh_profiles: Vec<SshProfile>,
    pub credential_profiles: Vec<CredentialProfile>,
    // Connections and profiles this build cannot read that the write takes out, as a deletion another device made,
    // under the same check.
    pub removing: Vec<Uuid>,
}

mod projects;

pub(super) use projects::{Landing, merge_projects};

// Where a group's name is its own: under its parent, or among its project's top-level groups.
type Place = (Option<Uuid>, Option<Uuid>);

fn place_of(group: &ConnectionGroup) -> Place {
    place(group.parent_id, group.project_id)
}

fn place(parent: Option<Uuid>, project: Option<Uuid>) -> Place {
    (parent, project.filter(|_| parent.is_none()))
}

#[derive(Debug, Clone)]
pub struct LibraryRead {
    pub list: ConnectionList,
    // SHA-256 in hex of the bytes the list came from, to check a host's tag against; a read vouches for nothing.
    pub digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rebuilt {
    // SHA-256 in hex of the bytes the file holds after the rebuild.
    pub digest: Option<String>,
    // Where a file this build could not read went, kept for the person to recover from.
    pub set_aside: Option<PathBuf>,
}

impl ConnectionStore {
    pub fn list_blocking(&self) -> Result<ConnectionList, StorageError> {
        let mut state = self.lock();
        Ok(self.ensure_loaded(&mut state)?.list())
    }

    pub fn read_library_blocking(&self) -> Result<LibraryRead, StorageError> {
        let mut state = self.lock();
        let list = self.ensure_loaded(&mut state)?.list();
        Ok(LibraryRead {
            list,
            digest: digest_of(&state),
        })
    }

    // Refused unless the file is still the one `over` names (None: no file), so nothing unchecked goes on; `build` reads it.
    // The secrets of what the write takes out go after it lands (`settle_secrets`), with the file's earlier ones.
    pub fn replace_library_blocking<E: From<StorageError>>(
        &self,
        over: Option<&str>,
        build: impl FnOnce(&ConnectionList) -> Result<LibraryWrite, E>,
        delete: impl FnMut(SecretOwner) -> bool,
    ) -> Result<Option<String>, E> {
        let mut state = self.lock_to_write();
        let before = self.vouched(&mut state, over)?;
        let document = before.written(build(&before.list())?)?;
        if document != before {
            self.commit_as(&mut state, document, Reported::ToCaller)?;
        } else if self.digest_on_disk()?.as_deref() != over {
            // Nothing written, so the file must still be the one it answers for.
            return Err(StorageError::LibraryChanged.into());
        }
        // The write has landed, so a cleanup that cannot be written stays listed for the next write, and the host still
        // gets the digest the file holds; an error here would leave it a tag for bytes the file no longer has.
        if let Err(error) = self.settle_secrets(&mut state, delete) {
            tracing::warn!(%error, "the secrets a library write took out stay listed for the next write");
        }
        Ok(digest_of(&state))
    }

    // For a file its host cannot vouch for: nothing it held goes on, and a new generation starts, as a restore's does.
    pub fn rebuild_library_blocking(&self, write: LibraryWrite, now: SystemTime) -> Result<Rebuilt, StorageError> {
        write.refuse_what_it_would_lose(&HashSet::new())?;
        // Nothing held goes on in a rebuild, so `removing` has nothing left to take out.
        let LibraryWrite {
            connections,
            groups,
            tags,
            favorites,
            projects,
            ssh_profiles,
            credential_profiles,
            removing: _,
        } = write;
        let mut state = self.lock_to_write();
        // A file that will not read, for its contents or for the system, goes aside whatever the store held before.
        let set_aside = match self.ensure_current(&mut state) {
            Ok(_) => None,
            Err(StorageError::DocumentUnavailable(_) | StorageError::Io { .. }) => {
                Some(crate::fs::move_aside_blocking(&self.inner.path, now)?)
            }
            Err(error) => return Err(error),
        };
        // Told against nothing, so no id from the file it replaces is journaled as a deletion to send.
        *state = StoreState::Unloaded;
        // The pending deletions go with the file: its ids are not vouched for, so the secrets they name stay.
        let document = ConnectionsDocument {
            connections: Lenient::from(connections),
            groups,
            tags,
            favorites,
            projects,
            ssh_profiles: Lenient::from(ssh_profiles),
            credential_profiles: Lenient::from(credential_profiles),
            secrets_to_delete: Lenient::default(),
            store: Some(StoreIdentity::fresh()),
        };
        self.commit_as(&mut state, document, Reported::ToCaller)?;
        Ok(Rebuilt {
            digest: digest_of(&state),
            set_aside,
        })
    }

    // Runs under the write lock the commit took, so no writer can bring an owner back between the check and the delete.
    // An owner whose id the file holds again keeps its secrets; one `delete` could not clear stays for the next write.
    fn settle_secrets(
        &self,
        state: &mut WriteGuard<'_>,
        mut delete: impl FnMut(SecretOwner) -> bool,
    ) -> Result<(), StorageError> {
        // Without the lock file another process could bring an owner back mid-way, so the list waits for a write with it.
        if !state.holds_file_lock() {
            return Ok(());
        }
        let StoreState::Ready(current, _) = &**state else {
            return Ok(());
        };
        if current.secrets_to_delete.is_empty() {
            return Ok(());
        }
        let mut document = (**current).clone();
        let held = [
            ids_of(&document.connections),
            ids_of(&document.ssh_profiles),
            ids_of(&document.credential_profiles),
        ];
        let pending = std::mem::take(&mut *document.secrets_to_delete);
        let left: Vec<SecretOwner> = pending
            .into_iter()
            .filter(|owner| !held[owner.kind.index()].contains(&owner.id) && !delete(*owner))
            .collect();
        *document.secrets_to_delete = left;
        if document != **current {
            // Part of the host's own write, whose digest goes back to it.
            self.commit_as(state, document, Reported::ToCaller)?;
        }
        Ok(())
    }

    // The file as the store holds it, refused unless it is still the one `over` names.
    fn vouched(&self, state: &mut WriteGuard<'_>, over: Option<&str>) -> Result<ConnectionsDocument, StorageError> {
        let before = match self.ensure_current(state) {
            Ok(before) => before,
            // A file swapped for one that does not read is a change too, and says so first.
            Err(StorageError::DocumentUnavailable(_)) if bytes_digest(state).as_deref() != over => {
                return Err(StorageError::LibraryChanged);
            }
            Err(error) => return Err(error),
        };
        if digest_of(state).as_deref() != over {
            return Err(StorageError::LibraryChanged);
        }
        Ok(before)
    }

    pub fn create_group_blocking(&self, group: ConnectionGroup) -> Result<ConnectionGroup, StorageError> {
        self.edit(|document| {
            if document.groups.iter().any(|held| held.id == group.id) {
                return Err(StorageError::GroupExists { id: group.id });
            }
            document.check_room(group.parent_id)?;
            let (_, project) = place_of(&group);
            document.check_project(project)?;
            if document.name_taken(place_of(&group), &group.name, &[]) {
                return Err(StorageError::GroupNameTaken {
                    name: group.name.as_str().to_owned(),
                });
            }
            let stored = ConnectionGroup {
                order: document.next_group_order(group.parent_id),
                project_id: project,
                ..group
            };
            document.groups.push(stored.clone());
            Ok(stored)
        })
    }

    pub fn rename_group_blocking(&self, id: Uuid, name: ConnectionGroupName) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.group_index(id)?;
            let at = place(
                GroupTree::new(&document.groups).parent(id),
                document.groups[index].project_id,
            );
            if document.name_taken(at, &name, &[id]) {
                return Err(StorageError::GroupNameTaken {
                    name: name.as_str().to_owned(),
                });
            }
            document.groups[index].name = name;
            Ok(())
        })
    }

    pub fn set_group_color_blocking(&self, id: Uuid, color: Option<ConnectionColor>) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.group_index(id)?;
            document.groups[index].color = color;
            Ok(())
        })
    }

    pub fn set_group_icon_blocking(&self, id: Uuid, icon: Option<LibraryIcon>) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.group_index(id)?;
            document.groups[index].icon = icon;
            Ok(())
        })
    }

    /// Ids the list lacks are skipped, as a drag from a list another
    /// window changed may carry one.
    pub fn move_groups_blocking(
        &self,
        ids: &[Uuid],
        parent: Option<Uuid>,
        before: Option<Uuid>,
    ) -> Result<(), StorageError> {
        self.edit(|document| {
            let moving: Vec<Uuid> = unique(ids)
                .into_iter()
                .filter(|id| document.groups.iter().any(|group| group.id == *id))
                .collect();
            if moving.is_empty() {
                return ids
                    .first()
                    .map_or(Ok(()), |&id| Err(StorageError::GroupNotFound { id }));
            }
            let ordered = document.check_group_move(&moving, parent, before)?;
            let known: HashSet<Uuid> = document.groups.iter().map(|group| group.id).collect();
            // A sibling whose parent has not arrived keeps it; one in a cycle takes `parent`, or it would nest in a moved group.
            for (rank, id) in ordered.iter().enumerate() {
                if let Some(group) = document.groups.iter_mut().find(|group| group.id == *id) {
                    if moving.contains(id) || group.parent_id.is_none_or(|stored| known.contains(&stored)) {
                        group.parent_id = parent;
                    }
                    group.order = rank_of(rank);
                }
            }
            Ok(())
        })
    }

    /// As on macOS, the subtree goes and its connections move to the top.
    pub fn delete_group_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        self.edit(|document| {
            let tree = GroupTree::new(&document.groups);
            if !tree.contains(id) {
                return Ok(RemoveOutcome::NotPresent);
            }
            let mut removed: HashSet<Uuid> = tree.descendants(id).into_iter().collect();
            removed.insert(id);
            let listed: HashMap<Uuid, usize> = tree
                .walk()
                .into_iter()
                .enumerate()
                .map(|(rank, group)| (group.id, rank))
                .collect();
            let mut freed: Vec<(usize, u32, Uuid)> = document
                .connections
                .iter()
                .filter_map(|connection| {
                    let group = connection.group_id.filter(|group| removed.contains(group))?;
                    Some((
                        listed.get(&group).copied().unwrap_or(usize::MAX),
                        connection.order,
                        connection.id,
                    ))
                })
                .collect();
            freed.sort();
            let moving: HashSet<Uuid> = freed.iter().map(|(_, _, id)| *id).collect();
            let mut ordered = document.connection_ids_in(None);
            ordered.extend(freed.into_iter().map(|(_, _, id)| id));
            document.groups.retain(|group| !removed.contains(&group.id));
            document.place_connections(None, &ordered, &moving);
            Ok(RemoveOutcome::Removed)
        })
    }

    pub fn move_connections_blocking(
        &self,
        ids: &[Uuid],
        group: Option<Uuid>,
        before: Option<Uuid>,
    ) -> Result<(), StorageError> {
        self.edit(|document| {
            if let Some(id) = group {
                document.group_index(id)?;
            }
            let moving = document.saved_ids(ids)?;
            let ordered = placed(&document.connection_ids_in(group), &moving, before);
            document.place_connections(group, &ordered, &moving.iter().copied().collect());
            Ok(())
        })
    }

    /// How the Linux app files a connection under a group it names, at the top in `project`.
    pub fn move_connections_to_group_named_blocking(
        &self,
        ids: &[Uuid],
        parent: Option<Uuid>,
        project: Option<Uuid>,
        name: ConnectionGroupName,
    ) -> Result<ConnectionGroup, StorageError> {
        self.edit(|document| {
            let moving = document.saved_ids(ids)?;
            let (_, project) = place(parent, project);
            document.check_project(project)?;
            let group = match document.group_named((parent, project), &name) {
                Some(group) => group,
                None => {
                    document.check_room(parent)?;
                    let group = ConnectionGroup {
                        order: document.next_group_order(parent),
                        project_id: project,
                        ..ConnectionGroup::new(name, parent)
                    };
                    document.groups.push(group.clone());
                    group
                }
            };
            let mut ordered = document.connection_ids_in(Some(group.id));
            let staying: HashSet<Uuid> = ordered.iter().copied().collect();
            let arriving: HashSet<Uuid> = moving.iter().copied().collect();
            ordered.extend(moving.into_iter().filter(|id| !staying.contains(id)));
            document.place_connections(Some(group.id), &ordered, &arriving);
            Ok(group)
        })
    }

    /// One already a favourite moves, which is how favourites reorder.
    pub fn add_favorites_blocking(&self, ids: &[Uuid], before: Option<Uuid>) -> Result<(), StorageError> {
        self.edit(|document| {
            let adding = document.saved_ids(ids)?;
            document.favorites = placed(&document.favorites, &adding, before);
            Ok(())
        })
    }

    pub fn remove_favorites_blocking(&self, ids: &[Uuid]) -> Result<(), StorageError> {
        self.edit(|document| {
            let leaving: HashSet<&Uuid> = ids.iter().collect();
            document.favorites.retain(|id| !leaving.contains(id));
            Ok(())
        })
    }
}

impl ConnectionsDocument {
    fn group_index(&self, id: Uuid) -> Result<usize, StorageError> {
        self.groups
            .iter()
            .position(|group| group.id == id)
            .ok_or(StorageError::GroupNotFound { id })
    }

    // Siblings as the tree files them: a group whose parent the list lacks sits at the top, and a top-level group's
    // siblings are the top-level groups of its project.
    fn name_taken(&self, at: Place, name: &ConnectionGroupName, except: &[Uuid]) -> bool {
        GroupTree::new(&self.groups).children(at.0).iter().any(|group| {
            place(at.0, group.project_id) == at && !except.contains(&group.id) && group.name.same_name(name)
        })
    }

    pub(super) fn group_named(&self, at: Place, name: &ConnectionGroupName) -> Option<ConnectionGroup> {
        let tree = GroupTree::new(&self.groups);
        let siblings: Vec<&ConnectionGroup> = tree
            .children(at.0)
            .into_iter()
            .filter(|group| place(at.0, group.project_id) == at)
            .collect();
        siblings
            .iter()
            .find(|group| group.name == *name)
            .or_else(|| siblings.iter().find(|group| group.name.same_name(name)))
            .map(|group| (*group).clone())
    }

    fn check_room(&self, parent: Option<Uuid>) -> Result<(), StorageError> {
        GroupTree::new(&self.groups).check_place(None, parent)
    }

    fn check_group_move(
        &self,
        moving: &[Uuid],
        parent: Option<Uuid>,
        before: Option<Uuid>,
    ) -> Result<Vec<Uuid>, StorageError> {
        let tree = GroupTree::new(&self.groups);
        // A reorder in place skips both checks, so case-only siblings and too deep groups still reorder.
        let arriving: Vec<&ConnectionGroup> = moving
            .iter()
            .filter_map(|id| tree.get(*id))
            .filter(|group| tree.parent(group.id) != parent)
            .collect();
        for group in &arriving {
            tree.check_place(Some(group.id), parent)?;
        }
        let siblings: Vec<&ConnectionGroup> = tree.children(parent);
        // A group that comes up to the top stays in the project of the top-level group it leaves.
        let membership = self.membership();
        let mut names: Vec<(Place, &ConnectionGroupName)> = siblings
            .iter()
            .map(|group| (place(parent, group.project_id), &group.name))
            .collect();
        for group in arriving {
            let landing = place(parent, membership.of_group(group.id));
            if names
                .iter()
                .any(|(at, name)| *at == landing && name.same_name(&group.name))
            {
                return Err(StorageError::GroupNameTaken {
                    name: group.name.as_str().to_owned(),
                });
            }
            names.push((landing, &group.name));
        }
        let ids: Vec<Uuid> = siblings.iter().map(|group| group.id).collect();
        Ok(placed(&ids, moving, before))
    }

    pub(super) fn saved_ids(&self, ids: &[Uuid]) -> Result<Vec<Uuid>, StorageError> {
        let saved: HashSet<Uuid> = self.connections.iter().map(|connection| connection.id).collect();
        let present: Vec<Uuid> = unique(ids).into_iter().filter(|id| saved.contains(id)).collect();
        match (present.is_empty(), ids.first()) {
            (true, Some(&id)) => Err(StorageError::ConnectionNotFound { id }),
            _ => Ok(present),
        }
    }

    fn connection_ids_in(&self, group: Option<Uuid>) -> Vec<Uuid> {
        let known: HashSet<Uuid> = self.groups.iter().map(|group| group.id).collect();
        let mut members: Vec<(u32, Uuid)> = self
            .connections
            .iter()
            .filter(|connection| connection.group_id.filter(|id| known.contains(id)) == group)
            .map(|connection| (connection.order, connection.id))
            .collect();
        members.sort_by_key(|(order, _)| *order);
        members.into_iter().map(|(_, id)| id).collect()
    }

    // Only `moving` changes group: an entry filed under a group that has not arrived keeps it.
    fn place_connections(&mut self, group: Option<Uuid>, ordered: &[Uuid], moving: &HashSet<Uuid>) {
        let ranks: HashMap<Uuid, usize> = ordered.iter().enumerate().map(|(rank, id)| (*id, rank)).collect();
        for connection in &mut self.connections {
            if let Some(rank) = ranks.get(&connection.id) {
                if moving.contains(&connection.id) {
                    connection.group_id = group;
                }
                connection.order = rank_of(*rank);
            }
        }
    }

    // Values as given; an entry this build cannot read stays unless the write names or removes it.
    fn written(&self, write: LibraryWrite) -> Result<Self, StorageError> {
        let named: HashSet<Uuid> = write.connections.iter().map(|connection| connection.id).collect();
        let held: HashSet<Uuid> = self
            .connections
            .held_ids()
            .into_iter()
            .filter(|id| !named.contains(id) && !write.removing.contains(id))
            .collect();
        write.refuse_what_it_would_lose(&held)?;
        // An id the file holds as two kinds is a crafted collision, and a removal cannot say which one it means.
        let kinds = [
            ids_of(&self.connections),
            ids_of(&self.ssh_profiles),
            ids_of(&self.credential_profiles),
        ];
        if let Some(&id) = write
            .removing
            .iter()
            .find(|id| kinds.iter().filter(|held| held.contains(id)).count() > 1)
        {
            return Err(StorageError::RepeatedId { id });
        }
        let LibraryWrite {
            connections,
            groups,
            tags,
            favorites,
            projects,
            ssh_profiles,
            credential_profiles,
            removing,
        } = write;
        let mut document = self.clone();
        for id in &removing {
            document.connections.remove_id(*id);
            document.ssh_profiles.remove_id(*id);
            document.credential_profiles.remove_id(*id);
        }
        replace_entries(&mut document.connections, connections);
        replace_entries(&mut document.ssh_profiles, ssh_profiles);
        replace_entries(&mut document.credential_profiles, credential_profiles);
        document.groups = groups;
        document.tags = tags;
        document.favorites = favorites;
        document.projects = projects;
        document.tidy();
        // A connection counts only when `removing` names it: the host keeps the secrets of the readable ones it leaves out.
        let leaving = gone(&self.connections, &document.connections)
            .into_iter()
            .filter(|id| removing.contains(id))
            .map(|id| SecretOwner::new(SecretOwnerKind::Connection, id))
            .chain(
                gone(&self.ssh_profiles, &document.ssh_profiles)
                    .into_iter()
                    .map(|id| SecretOwner::new(SecretOwnerKind::SshProfile, id)),
            )
            .chain(
                gone(&self.credential_profiles, &document.credential_profiles)
                    .into_iter()
                    .map(|id| SecretOwner::new(SecretOwnerKind::CredentialProfile, id)),
            );
        for owner in leaving {
            if !document.secrets_to_delete.contains(&owner) {
                document.secrets_to_delete.push(owner);
            }
        }
        Ok(document)
    }
}

// A held entry the write names gives way to the one it brings.
fn replace_entries<T: Identified>(list: &mut Lenient<T>, entries: Vec<T>) {
    for entry in &entries {
        list.release(entry.id());
    }
    **list = entries;
}

fn ids_of<T: Identified>(list: &Lenient<T>) -> HashSet<Uuid> {
    list.iter().map(Identified::id).chain(list.held_ids()).collect()
}

// Ids `before` holds, read or held, that `after` no longer does, in the order `before` lists them.
fn gone<T: Identified>(before: &Lenient<T>, after: &Lenient<T>) -> Vec<Uuid> {
    let kept = ids_of(after);
    before
        .iter()
        .map(Identified::id)
        .chain(before.held_ids())
        .filter(|id| !kept.contains(id))
        .collect()
}

impl LibraryWrite {
    // Refused, not dropped: a repeated id or tag, or a favourite of no connection the file keeps (`held` stays).
    fn refuse_what_it_would_lose(&self, held: &HashSet<Uuid>) -> Result<(), StorageError> {
        let repeated = first_repeat(self.connections.iter().map(|connection| connection.id))
            .or_else(|| first_repeat(self.groups.iter().map(|group| group.id)))
            .or_else(|| first_repeat(self.tags.iter().map(|tag| tag.id)))
            .or_else(|| first_repeat(self.projects.iter().map(|project| project.id)))
            .or_else(|| first_repeat(self.favorites.iter().copied()))
            .or_else(|| first_repeat(self.ssh_profiles.iter().map(|profile| profile.id)))
            .or_else(|| first_repeat(self.credential_profiles.iter().map(|profile| profile.id)))
            .or_else(|| {
                self.connections
                    .iter()
                    .find_map(|connection| first_repeat(connection.tags.iter().copied()))
            });
        let saved: HashSet<Uuid> = self.connections.iter().map(|connection| connection.id).collect();
        let kept: HashSet<Uuid> = self
            .ssh_profiles
            .iter()
            .map(|profile| profile.id)
            .chain(self.credential_profiles.iter().map(|profile| profile.id))
            .chain(saved.iter().copied())
            .collect();
        // An entry the write both keeps and takes out is named twice.
        let kept_and_removed = self.removing.iter().copied().find(|id| kept.contains(id));
        if let Some(id) = repeated.or(kept_and_removed) {
            return Err(StorageError::RepeatedId { id });
        }
        match self
            .favorites
            .iter()
            .find(|id| !saved.contains(id) && !held.contains(id))
        {
            Some(&id) => Err(StorageError::ConnectionNotFound { id }),
            None => Ok(()),
        }
    }
}

fn digest_of(state: &StoreState) -> Option<String> {
    match state {
        StoreState::Ready(_, Some(bytes)) => Some(sha256_hex(bytes)),
        StoreState::Ready(_, None) | StoreState::Unloaded | StoreState::Unavailable(..) => None,
    }
}

// Of the bytes the store last read, whether they decoded or not.
pub(super) fn bytes_digest(state: &StoreState) -> Option<String> {
    match state {
        StoreState::Ready(_, Some(bytes)) | StoreState::Unavailable(_, Some(Some(bytes))) => Some(sha256_hex(bytes)),
        StoreState::Ready(_, None) | StoreState::Unloaded | StoreState::Unavailable(..) => None,
    }
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

impl ConnectionStore {
    fn digest_on_disk(&self) -> Result<Option<String>, StorageError> {
        match std::fs::read(&self.inner.path) {
            Ok(bytes) => Ok(Some(sha256_hex(&bytes))),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(source) => Err(StorageError::Io {
                path: self.inner.path.clone(),
                source,
            }),
        }
    }
}

fn first_repeat(ids: impl Iterator<Item = Uuid>) -> Option<Uuid> {
    let mut seen = HashSet::new();
    ids.into_iter().find(|id| !seen.insert(*id))
}

fn rank_of(rank: usize) -> u32 {
    u32::try_from(rank).unwrap_or(u32::MAX)
}

// A group matched by id keeps its place, so an import never makes a cycle.
pub(super) fn merge_groups(
    local: &mut Vec<ConnectionGroup>,
    incoming: &[ConnectionGroup],
    landing: &Landing<'_>,
) -> HashMap<Uuid, Uuid> {
    // Maps rather than scans, so a crafted file of many groups cannot hold the store for minutes.
    let mut at: HashMap<Uuid, usize> = local
        .iter()
        .enumerate()
        .map(|(index, group)| (group.id, index))
        .collect();
    // Where each group reads: one whose parent has not arrived, or in a cycle, sits at the top.
    let under_of: HashMap<Uuid, Option<Uuid>> = {
        let tree = GroupTree::new(local.as_slice());
        local.iter().map(|group| (group.id, tree.parent(group.id))).collect()
    };
    let spot_of = |group: &ConnectionGroup| place(under_of.get(&group.id).copied().flatten(), group.project_id);
    let mut depth: HashMap<Uuid, usize> = HashMap::with_capacity(local.len());
    for group in GroupTree::new(local.as_slice()).walk() {
        let above = under_of
            .get(&group.id)
            .copied()
            .flatten()
            .and_then(|id| depth.get(&id).copied())
            .unwrap_or(0);
        depth.insert(group.id, above + 1);
    }
    let mut names = SiblingNames::default();
    let mut next: HashMap<Option<Uuid>, u32> = HashMap::new();
    for group in local.iter() {
        names.add(spot_of(group), group);
        let last = next.entry(under_of.get(&group.id).copied().flatten()).or_insert(0);
        *last = (*last).max(group.order.saturating_add(1));
    }
    // Parents before their children, so each finds its parent mapped.
    let walk = GroupTree::new(incoming).walk();
    // Renames first, so a name one of them frees or takes decides the rest whatever order the file lists them in.
    for group in &walk {
        if let Some(&index) = at.get(&group.id) {
            let spot = spot_of(&local[index]);
            let held = &mut local[index];
            if !names.taken_by_another(spot, &group.name, held.id) {
                names.remove(spot, held);
                held.name = group.name.clone();
                names.add(spot, held);
            }
            held.color = group.color;
            held.icon = group.icon.clone();
        }
    }
    let mut same: HashMap<Uuid, Uuid> = HashMap::with_capacity(incoming.len());
    for group in walk {
        let parent = group.parent_id.and_then(|id| same.get(&id).copied());
        let full = parent.filter(|id| depth.get(id).is_some_and(|level| *level >= ConnectionGroup::MAX_DEPTH));
        // A file's top-level group that a full path folded away has a parent here, so no project of its own.
        let spot = place(
            parent,
            landing.project(group.project_id.filter(|_| group.parent_id.is_none())),
        );
        if at.contains_key(&group.id) {
            same.insert(group.id, group.id);
        } else if let Some(deepest) = full {
            // macOS cuts the path the same way, so the connections land in the deepest group allowed.
            same.insert(group.id, deepest);
        } else if let Some(owner) = names
            .exactly(spot, &group.name)
            .or_else(|| names.in_any_case(spot, &group.name))
        {
            same.insert(group.id, owner);
        } else {
            let order = next.entry(parent).or_insert(0);
            let added = ConnectionGroup {
                parent_id: parent,
                project_id: spot.1,
                order: *order,
                ..group.clone()
            };
            *order = order.saturating_add(1);
            let above = parent.and_then(|id| depth.get(&id).copied()).unwrap_or(0);
            depth.insert(added.id, above + 1);
            at.insert(added.id, local.len());
            names.add_exact(spot, &added);
            same.insert(group.id, added.id);
            local.push(added);
        }
    }
    same
}

// The file's groups down to `leaf` for an entry that keeps its project, matched by name alone so the
// groups the import landed elsewhere stay there. None when the file names a project, which then decides.
pub(super) fn merge_group_path(
    local: &mut Vec<ConnectionGroup>,
    incoming: &[ConnectionGroup],
    leaf: Uuid,
    landing: &Landing<'_>,
) -> Option<Uuid> {
    let by_id: HashMap<Uuid, &ConnectionGroup> = incoming.iter().map(|group| (group.id, group)).collect();
    let mut path: Vec<&ConnectionGroup> = Vec::new();
    let mut seen = HashSet::new();
    let mut next = Some(leaf);
    while let Some(group) = next.and_then(|id| by_id.get(&id).copied()) {
        if !seen.insert(group.id) {
            return None;
        }
        path.push(group);
        next = group.parent_id;
    }
    let root = path.last()?;
    if root.parent_id.is_some() || landing.named(root.project_id).is_some() {
        return None;
    }
    let mut parent = None;
    let mut copies = Vec::with_capacity(path.len());
    for group in path.into_iter().rev() {
        let copy = ConnectionGroup {
            id: Uuid::new_v4(),
            parent_id: parent,
            ..group.clone()
        };
        parent = Some(copy.id);
        copies.push(copy);
    }
    let same = merge_groups(local, &copies, landing);
    parent.and_then(|id| same.get(&id).copied())
}

// By names as they show, a stored name kept as written and a file's cleaned; a top-level group is placed in its project.
#[derive(Default)]
struct SiblingNames {
    exact: HashMap<(Place, String), Uuid>,
    folded: HashMap<(Place, String), Vec<Uuid>>,
}

impl SiblingNames {
    fn add(&mut self, at: Place, group: &ConnectionGroup) {
        self.add_exact(at, group);
        self.folded
            .entry((at, group.name.shown().to_lowercase()))
            .or_default()
            .push(group.id);
    }

    // An added group stays out of the any-case match, so a file's own `Work` and `work` stay two groups.
    fn add_exact(&mut self, at: Place, group: &ConnectionGroup) {
        self.exact.entry((at, group.name.shown())).or_insert(group.id);
    }

    fn remove(&mut self, at: Place, group: &ConnectionGroup) {
        let exact = (at, group.name.shown());
        if self.exact.get(&exact) == Some(&group.id) {
            self.exact.remove(&exact);
        }
        if let Some(ids) = self.folded.get_mut(&(at, group.name.shown().to_lowercase())) {
            ids.retain(|id| *id != group.id);
        }
    }

    fn exactly(&self, at: Place, name: &ConnectionGroupName) -> Option<Uuid> {
        self.exact.get(&(at, name.shown())).copied()
    }

    fn in_any_case(&self, at: Place, name: &ConnectionGroupName) -> Option<Uuid> {
        self.folded
            .get(&(at, name.shown().to_lowercase()))
            .and_then(|ids| ids.first().copied())
    }

    fn taken_by_another(&self, at: Place, name: &ConnectionGroupName, except: Uuid) -> bool {
        self.folded
            .get(&(at, name.shown().to_lowercase()))
            .is_some_and(|ids| ids.iter().any(|id| *id != except))
    }
}

#[cfg(test)]
mod project_tests;
#[cfg(test)]
mod tests;
