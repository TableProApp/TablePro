use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use super::placement::{placed, unique};
use super::{ConnectionList, ConnectionStore, ConnectionsDocument, RemoveOutcome};
use crate::error::StorageError;
use crate::{ConnectionColor, ConnectionGroup, ConnectionGroupName, GroupIcon, GroupTree};

impl ConnectionStore {
    pub fn list_blocking(&self) -> Result<ConnectionList, StorageError> {
        let mut state = self.lock();
        Ok(self.ensure_loaded(&mut state)?.list())
    }

    pub fn create_group_blocking(&self, group: ConnectionGroup) -> Result<ConnectionGroup, StorageError> {
        self.edit(|document| {
            if document.groups.iter().any(|held| held.id == group.id) {
                return Err(StorageError::GroupExists { id: group.id });
            }
            document.check_room(group.parent_id, 0)?;
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
            if document.name_taken(document.groups[index].parent_id, &name, &[id]) {
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

    pub fn set_group_icon_blocking(&self, id: Uuid, icon: Option<GroupIcon>) -> Result<(), StorageError> {
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
            for (rank, id) in ordered.iter().enumerate() {
                if let Some(group) = document.groups.iter_mut().find(|group| group.id == *id) {
                    group.parent_id = parent;
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
            let mut ordered = document.connection_ids_in(None);
            ordered.extend(freed.into_iter().map(|(_, _, id)| id));
            document.groups.retain(|group| !removed.contains(&group.id));
            document.place_connections(None, &ordered);
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
            document.place_connections(group, &ordered);
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
                    document.check_room(parent, 0)?;
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
            ordered.extend(moving.into_iter().filter(|id| !staying.contains(id)));
            document.place_connections(Some(group.id), &ordered);
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

    fn name_taken(&self, parent: Option<Uuid>, name: &ConnectionGroupName, except: &[Uuid]) -> bool {
        self.groups
            .iter()
            .any(|group| group.parent_id == parent && !except.contains(&group.id) && group.name.same_name(name))
    }

    pub(super) fn group_named(&self, parent: Option<Uuid>, name: &ConnectionGroupName) -> Option<ConnectionGroup> {
        let siblings: Vec<&ConnectionGroup> = self.groups.iter().filter(|group| group.parent_id == parent).collect();
        siblings
            .iter()
            .find(|group| group.name == *name)
            .or_else(|| siblings.iter().find(|group| group.name.same_name(name)))
            .map(|group| (*group).clone())
    }

    fn check_room(&self, parent: Option<Uuid>, height: usize) -> Result<(), StorageError> {
        let tree = GroupTree::new(&self.groups);
        if let Some(id) = parent
            && !tree.contains(id)
        {
            return Err(StorageError::GroupNotFound { id });
        }
        if tree.depth(parent) + 1 + height > ConnectionGroup::MAX_DEPTH {
            return Err(StorageError::GroupTooDeep {
                max: ConnectionGroup::MAX_DEPTH,
            });
        }
        Ok(())
    }

    fn check_group_move(
        &self,
        moving: &[Uuid],
        parent: Option<Uuid>,
        before: Option<Uuid>,
    ) -> Result<Vec<Uuid>, StorageError> {
        let tree = GroupTree::new(&self.groups);
        for &id in moving {
            if let Some(target) = parent
                && (target == id || tree.descendants(id).contains(&target))
            {
                return Err(StorageError::GroupCycle { id });
            }
            self.check_room(parent, tree.height(id))?;
        }
        let siblings: Vec<&ConnectionGroup> = tree.children(parent);
        let mut names: Vec<&ConnectionGroupName> = siblings
            .iter()
            .filter(|group| !moving.contains(&group.id))
            .map(|group| &group.name)
            .collect();
        for group in moving.iter().filter_map(|id| tree.get(*id)) {
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
        let mut members: Vec<(u32, Uuid)> = self
            .connections
            .iter()
            .filter(|connection| connection.group_id == group)
            .map(|connection| (connection.order, connection.id))
            .collect();
        members.sort_by_key(|(order, _)| *order);
        members.into_iter().map(|(_, id)| id).collect()
    }

    fn place_connections(&mut self, group: Option<Uuid>, ordered: &[Uuid]) {
        let ranks: HashMap<Uuid, usize> = ordered.iter().enumerate().map(|(rank, id)| (*id, rank)).collect();
        for connection in &mut self.connections {
            if let Some(rank) = ranks.get(&connection.id) {
                connection.group_id = group;
                connection.order = rank_of(*rank);
            }
        }
    }
}

fn rank_of(rank: usize) -> u32 {
    u32::try_from(rank).unwrap_or(u32::MAX)
}

/// Returns the local id each of the file's group ids now stands for. A
/// group matched by id keeps its local place, so an import never makes a
/// cycle. Names match exactly, as the version 2 upgrade merged them.
pub(super) fn merge_groups(local: &mut Vec<ConnectionGroup>, incoming: &[ConnectionGroup]) -> HashMap<Uuid, Uuid> {
    // Maps rather than scans: a crafted file of many groups must not make
    // an import hold the store for minutes.
    let mut at: HashMap<Uuid, usize> = local
        .iter()
        .enumerate()
        .map(|(index, group)| (group.id, index))
        .collect();
    let mut names = SiblingNames::default();
    let mut next: HashMap<Option<Uuid>, u32> = HashMap::new();
    for group in local.iter() {
        names.add(group);
        let last = next.entry(group.parent_id).or_insert(0);
        *last = (*last).max(group.order.saturating_add(1));
    }
    let mut same = HashMap::with_capacity(incoming.len());
    // Parents before their children, so each finds its parent mapped.
    for group in GroupTree::new(incoming).walk() {
        let parent = group.parent_id.and_then(|id| same.get(&id).copied());
        if let Some(&index) = at.get(&group.id) {
            let held = &mut local[index];
            if !names.taken_by_another(held.parent_id, &group.name, held.id) {
                names.remove(held);
                held.name = group.name.clone();
                names.add(held);
            }
            held.color = group.color;
            held.icon = group.icon.clone();
            same.insert(group.id, group.id);
        } else if let Some(owner) = names.exactly(parent, &group.name) {
            same.insert(group.id, owner);
        } else {
            let order = next.entry(parent).or_insert(0);
            let added = ConnectionGroup {
                parent_id: parent,
                order: *order,
                ..group.clone()
            };
            *order = order.saturating_add(1);
            at.insert(added.id, local.len());
            names.add(&added);
            same.insert(group.id, added.id);
            local.push(added);
        }
    }
    same
}

#[derive(Default)]
struct SiblingNames {
    exact: HashMap<(Option<Uuid>, String), Uuid>,
    folded: HashMap<(Option<Uuid>, String), HashSet<Uuid>>,
}

impl SiblingNames {
    fn add(&mut self, group: &ConnectionGroup) {
        self.exact
            .entry((group.parent_id, group.name.as_str().to_owned()))
            .or_insert(group.id);
        self.folded
            .entry((group.parent_id, group.name.as_str().to_lowercase()))
            .or_default()
            .insert(group.id);
    }

    fn remove(&mut self, group: &ConnectionGroup) {
        let exact = (group.parent_id, group.name.as_str().to_owned());
        if self.exact.get(&exact) == Some(&group.id) {
            self.exact.remove(&exact);
        }
        if let Some(ids) = self
            .folded
            .get_mut(&(group.parent_id, group.name.as_str().to_lowercase()))
        {
            ids.remove(&group.id);
        }
    }

    fn exactly(&self, parent: Option<Uuid>, name: &ConnectionGroupName) -> Option<Uuid> {
        self.exact.get(&(parent, name.as_str().to_owned())).copied()
    }

    fn taken_by_another(&self, parent: Option<Uuid>, name: &ConnectionGroupName, except: Uuid) -> bool {
        self.folded
            .get(&(parent, name.as_str().to_lowercase()))
            .is_some_and(|ids| ids.iter().any(|id| *id != except))
    }
}

#[cfg(test)]
mod tests;
