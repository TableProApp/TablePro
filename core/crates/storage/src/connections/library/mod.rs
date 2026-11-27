use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::SystemTime;

use uuid::Uuid;

use super::placement::{placed, unique};
use super::{
    ConnectionList, ConnectionStore, ConnectionsDocument, RemoveOutcome, Reported, SavedConnection, StoreState,
};
use crate::error::StorageError;
use crate::lenient::Lenient;
use crate::store_identity::StoreIdentity;
use crate::{ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionTag, GroupTree, LibraryIcon};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LibraryWrite {
    pub connections: Vec<SavedConnection>,
    pub groups: Vec<ConnectionGroup>,
    pub tags: Vec<ConnectionTag>,
    pub favorites: Vec<Uuid>,
    // Entries this build cannot read that the write takes out, as a deletion another device made, under the same check.
    pub removing: Vec<Uuid>,
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
    pub fn replace_library_blocking<E: From<StorageError>>(
        &self,
        over: Option<&str>,
        build: impl FnOnce(&ConnectionList) -> Result<LibraryWrite, E>,
    ) -> Result<Option<String>, E> {
        let mut state = self.lock_to_write();
        let before = match self.ensure_current(&mut state) {
            Ok(before) => before,
            // A file swapped for one that does not read is a change too, and says so first.
            Err(StorageError::DocumentUnavailable(_)) if bytes_digest(&state).as_deref() != over => {
                return Err(StorageError::LibraryChanged.into());
            }
            Err(error) => return Err(error.into()),
        };
        if digest_of(&state).as_deref() != over {
            return Err(StorageError::LibraryChanged.into());
        }
        let write = build(&before.list())?;
        let named: HashSet<Uuid> = write.connections.iter().map(|connection| connection.id).collect();
        let held: HashSet<Uuid> = before
            .connections
            .held_ids()
            .into_iter()
            .filter(|id| !named.contains(id) && !write.removing.contains(id))
            .collect();
        write.refuse_what_it_would_lose(&held)?;
        let LibraryWrite {
            connections,
            groups,
            tags,
            favorites,
            removing,
        } = write;
        let mut document = before.clone();
        for id in removing {
            document.connections.remove_id(id);
        }
        for connection in &connections {
            document.connections.release(connection.id);
        }
        *document.connections = connections;
        document.groups = groups;
        document.tags = tags;
        document.favorites = favorites;
        document.tidy();
        if document != before {
            self.commit_as(&mut state, document, Reported::ToCaller)?;
        } else if self.digest_on_disk()?.as_deref() != over {
            // Nothing written, so the file must still be the one it answers for.
            return Err(StorageError::LibraryChanged.into());
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
        let document = ConnectionsDocument {
            connections: Lenient::from(connections),
            groups,
            tags,
            favorites,
            store: Some(StoreIdentity::fresh()),
            ..ConnectionsDocument::default()
        };
        self.commit_as(&mut state, document, Reported::ToCaller)?;
        Ok(Rebuilt {
            digest: digest_of(&state),
            set_aside,
        })
    }

    pub fn create_group_blocking(&self, group: ConnectionGroup) -> Result<ConnectionGroup, StorageError> {
        self.edit(|document| {
            if document.groups.iter().any(|held| held.id == group.id) {
                return Err(StorageError::GroupExists { id: group.id });
            }
            document.check_room(group.parent_id)?;
            if document.name_taken(group.parent_id, &group.name, &[]) {
                return Err(StorageError::GroupNameTaken {
                    name: group.name.as_str().to_owned(),
                });
            }
            let stored = ConnectionGroup {
                order: document.next_group_order(group.parent_id),
                ..group
            };
            document.groups.push(stored.clone());
            Ok(stored)
        })
    }

    pub fn rename_group_blocking(&self, id: Uuid, name: ConnectionGroupName) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.group_index(id)?;
            if document.name_taken(GroupTree::new(&document.groups).parent(id), &name, &[id]) {
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

    /// How the Linux app files a connection under a group it names.
    pub fn move_connections_to_group_named_blocking(
        &self,
        ids: &[Uuid],
        parent: Option<Uuid>,
        name: ConnectionGroupName,
    ) -> Result<ConnectionGroup, StorageError> {
        self.edit(|document| {
            let moving = document.saved_ids(ids)?;
            let group = match document.group_named(parent, &name) {
                Some(group) => group,
                None => {
                    document.check_room(parent)?;
                    let group = ConnectionGroup {
                        order: document.next_group_order(parent),
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

    // Siblings as the tree files them: a group whose parent the list lacks sits at the top.
    fn name_taken(&self, parent: Option<Uuid>, name: &ConnectionGroupName, except: &[Uuid]) -> bool {
        GroupTree::new(&self.groups)
            .children(parent)
            .iter()
            .any(|group| !except.contains(&group.id) && group.name.same_name(name))
    }

    pub(super) fn group_named(&self, parent: Option<Uuid>, name: &ConnectionGroupName) -> Option<ConnectionGroup> {
        let tree = GroupTree::new(&self.groups);
        let siblings: Vec<&ConnectionGroup> = tree.children(parent);
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
        let mut names: Vec<&ConnectionGroupName> = siblings.iter().map(|group| &group.name).collect();
        for group in arriving {
            if names.iter().any(|name| name.same_name(&group.name)) {
                return Err(StorageError::GroupNameTaken {
                    name: group.name.as_str().to_owned(),
                });
            }
            names.push(&group.name);
        }
        let ids: Vec<Uuid> = siblings.iter().map(|group| group.id).collect();
        Ok(placed(&ids, moving, before))
    }

    fn saved_ids(&self, ids: &[Uuid]) -> Result<Vec<Uuid>, StorageError> {
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
}

impl LibraryWrite {
    // Refused, not dropped: a repeated id or tag, or a favourite of no connection the file keeps (`held` stays).
    fn refuse_what_it_would_lose(&self, held: &HashSet<Uuid>) -> Result<(), StorageError> {
        let repeated = first_repeat(self.connections.iter().map(|connection| connection.id))
            .or_else(|| first_repeat(self.groups.iter().map(|group| group.id)))
            .or_else(|| first_repeat(self.tags.iter().map(|tag| tag.id)))
            .or_else(|| first_repeat(self.favorites.iter().copied()))
            .or_else(|| {
                self.connections
                    .iter()
                    .find_map(|connection| first_repeat(connection.tags.iter().copied()))
            });
        let saved: HashSet<Uuid> = self.connections.iter().map(|connection| connection.id).collect();
        // A connection the write both keeps and takes out is named twice.
        let kept_and_removed = self.removing.iter().copied().find(|id| saved.contains(id));
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
pub(super) fn merge_groups(local: &mut Vec<ConnectionGroup>, incoming: &[ConnectionGroup]) -> HashMap<Uuid, Uuid> {
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
        names.add(under_of.get(&group.id).copied().flatten(), group);
        let last = next.entry(under_of.get(&group.id).copied().flatten()).or_insert(0);
        *last = (*last).max(group.order.saturating_add(1));
    }
    // Parents before their children, so each finds its parent mapped.
    let walk = GroupTree::new(incoming).walk();
    // Renames first, so a name one of them frees or takes decides the rest whatever order the file lists them in.
    for group in &walk {
        if let Some(&index) = at.get(&group.id) {
            let held = &mut local[index];
            let under = under_of.get(&held.id).copied().flatten();
            if !names.taken_by_another(under, &group.name, held.id) {
                names.remove(under, held);
                held.name = group.name.clone();
                names.add(under, held);
            }
            held.color = group.color;
            held.icon = group.icon.clone();
        }
    }
    let mut same: HashMap<Uuid, Uuid> = HashMap::with_capacity(incoming.len());
    for group in walk {
        let parent = group.parent_id.and_then(|id| same.get(&id).copied());
        let full = parent.filter(|id| depth.get(id).is_some_and(|level| *level >= ConnectionGroup::MAX_DEPTH));
        if at.contains_key(&group.id) {
            same.insert(group.id, group.id);
        } else if let Some(deepest) = full {
            // macOS cuts the path the same way, so the connections land in the deepest group allowed.
            same.insert(group.id, deepest);
        } else if let Some(owner) = names
            .exactly(parent, &group.name)
            .or_else(|| names.in_any_case(parent, &group.name))
        {
            same.insert(group.id, owner);
        } else {
            let order = next.entry(parent).or_insert(0);
            let added = ConnectionGroup {
                parent_id: parent,
                order: *order,
                ..group.clone()
            };
            *order = order.saturating_add(1);
            let above = parent.and_then(|id| depth.get(&id).copied()).unwrap_or(0);
            depth.insert(added.id, above + 1);
            at.insert(added.id, local.len());
            names.add_exact(parent, &added);
            same.insert(group.id, added.id);
            local.push(added);
        }
    }
    same
}

// By names as they show: a stored name is kept as written, a file's is cleaned.
#[derive(Default)]
struct SiblingNames {
    exact: HashMap<(Option<Uuid>, String), Uuid>,
    folded: HashMap<(Option<Uuid>, String), Vec<Uuid>>,
}

impl SiblingNames {
    fn add(&mut self, parent: Option<Uuid>, group: &ConnectionGroup) {
        self.add_exact(parent, group);
        self.folded
            .entry((parent, group.name.shown().to_lowercase()))
            .or_default()
            .push(group.id);
    }

    // An added group stays out of the any-case match, so a file's own `Work` and `work` stay two groups.
    fn add_exact(&mut self, parent: Option<Uuid>, group: &ConnectionGroup) {
        self.exact.entry((parent, group.name.shown())).or_insert(group.id);
    }

    fn remove(&mut self, parent: Option<Uuid>, group: &ConnectionGroup) {
        let exact = (parent, group.name.shown());
        if self.exact.get(&exact) == Some(&group.id) {
            self.exact.remove(&exact);
        }
        if let Some(ids) = self.folded.get_mut(&(parent, group.name.shown().to_lowercase())) {
            ids.retain(|id| *id != group.id);
        }
    }

    fn exactly(&self, parent: Option<Uuid>, name: &ConnectionGroupName) -> Option<Uuid> {
        self.exact.get(&(parent, name.shown())).copied()
    }

    fn in_any_case(&self, parent: Option<Uuid>, name: &ConnectionGroupName) -> Option<Uuid> {
        self.folded
            .get(&(parent, name.shown().to_lowercase()))
            .and_then(|ids| ids.first().copied())
    }

    fn taken_by_another(&self, parent: Option<Uuid>, name: &ConnectionGroupName, except: Uuid) -> bool {
        self.folded
            .get(&(parent, name.shown().to_lowercase()))
            .is_some_and(|ids| ids.iter().any(|id| *id != except))
    }
}

#[cfg(test)]
mod tests;
