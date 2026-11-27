use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use super::place_of;
use crate::connections::placement::{placed, unique};
use crate::connections::{ConnectionStore, ConnectionsDocument, RemoveOutcome};
use crate::error::StorageError;
use crate::{ConnectionColor, ConnectionGroupName, ConnectionProject, ConnectionProjectName, LibraryIcon};

impl ConnectionStore {
    pub fn create_project_blocking(&self, project: ConnectionProject) -> Result<ConnectionProject, StorageError> {
        self.edit(|document| {
            if document.projects.iter().any(|held| held.id == project.id) {
                return Err(StorageError::ProjectExists { id: project.id });
            }
            document.check_project_name(&project.name, None)?;
            let order = document
                .projects
                .iter()
                .map(|held| held.order)
                .max()
                .map_or(0, |last| last.saturating_add(1));
            let stored = ConnectionProject { order, ..project };
            document.projects.push(stored.clone());
            Ok(stored)
        })
    }

    pub fn rename_project_blocking(&self, id: Uuid, name: ConnectionProjectName) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.project_index(id)?;
            document.check_project_name(&name, Some(id))?;
            document.projects[index].name = name;
            Ok(())
        })
    }

    pub fn set_project_color_blocking(&self, id: Uuid, color: Option<ConnectionColor>) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.project_index(id)?;
            document.projects[index].color = color;
            Ok(())
        })
    }

    pub fn set_project_icon_blocking(&self, id: Uuid, icon: Option<LibraryIcon>) -> Result<(), StorageError> {
        self.edit(|document| {
            let index = document.project_index(id)?;
            document.projects[index].icon = icon;
            Ok(())
        })
    }

    // Its groups and connections stay, in no project.
    pub fn delete_project_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        self.edit(|document| {
            let before = document.projects.len();
            document.projects.retain(|project| project.id != id);
            if document.projects.len() == before {
                return Ok(RemoveOutcome::NotPresent);
            }
            document.number_projects();
            for group in &mut document.groups {
                if group.project_id == Some(id) {
                    group.project_id = None;
                }
            }
            for connection in document.connections.iter_mut() {
                if connection.project_id == Some(id) {
                    connection.project_id = None;
                }
            }
            Ok(RemoveOutcome::Removed)
        })
    }

    // Ids the list lacks are skipped, as the group moves skip them.
    pub fn move_projects_blocking(&self, ids: &[Uuid], before: Option<Uuid>) -> Result<(), StorageError> {
        self.edit(|document| {
            let moving: Vec<Uuid> = unique(ids)
                .into_iter()
                .filter(|id| document.projects.iter().any(|project| project.id == *id))
                .collect();
            if moving.is_empty() {
                return ids
                    .first()
                    .map_or(Ok(()), |&id| Err(StorageError::ProjectNotFound { id }));
            }
            let mut ordered: Vec<(u32, Uuid)> = document
                .projects
                .iter()
                .map(|project| (project.order, project.id))
                .collect();
            ordered.sort_by_key(|(order, _)| *order);
            let ordered: Vec<Uuid> = ordered.into_iter().map(|(_, id)| id).collect();
            let ranks: HashMap<Uuid, usize> = placed(&ordered, &moving, before)
                .into_iter()
                .enumerate()
                .map(|(rank, id)| (id, rank))
                .collect();
            for project in &mut document.projects {
                if let Some(rank) = ranks.get(&project.id) {
                    project.order = u32::try_from(*rank).unwrap_or(u32::MAX);
                }
            }
            Ok(())
        })
    }

    // A project's export names no other project and no tag only another one uses; `None` is the whole list. A project
    // the list no longer holds is refused rather than widened to the whole list. Gives the bytes and their connections.
    pub fn export_scoped_blocking(&self, project: Option<Uuid>) -> Result<(Vec<u8>, usize), StorageError> {
        let mut state = self.lock();
        // What any export writes: the connections as a file carries them and nothing this build could not read.
        let document = self.ensure_loaded(&mut state)?.exported();
        let list = document.list();
        let Some(asked) = project else {
            return Ok((crate::document::encode_document(&document)?, list.connections.len()));
        };
        let Some(project) = list.resolved_scope(Some(asked)) else {
            return Err(StorageError::ProjectNotFound { id: asked });
        };
        let scoped = list.scoped(Some(project));
        let used: HashSet<Uuid> = scoped
            .connections
            .iter()
            .flat_map(|connection| connection.tags.iter().copied())
            .collect();
        let part = ConnectionsDocument {
            connections: scoped.connections.to_vec().into(),
            groups: scoped.groups.to_vec(),
            tags: scoped
                .tags
                .iter()
                .filter(|tag| used.contains(&tag.id))
                .cloned()
                .collect(),
            favorites: scoped.favorites.to_vec(),
            projects: scoped
                .projects
                .iter()
                .filter(|held| held.id == project)
                .cloned()
                .collect(),
            ..ConnectionsDocument::default()
        };
        Ok((crate::document::encode_document(&part)?, part.connections.len()))
    }

    // A grouped connection is refused: moving its top-level group would take the ones beside it along.
    pub fn move_connections_to_project_blocking(
        &self,
        ids: &[Uuid],
        project: Option<Uuid>,
    ) -> Result<(), StorageError> {
        self.edit(|document| {
            document.check_project(project)?;
            let moving = document.saved_ids(ids)?;
            for connection in &mut document.connections {
                if !moving.contains(&connection.id) {
                    continue;
                }
                if connection.group_id.is_some() {
                    return Err(StorageError::ConnectionGrouped { id: connection.id });
                }
                connection.project_id = project;
            }
            Ok(())
        })
    }

    pub fn move_groups_to_project_blocking(&self, ids: &[Uuid], project: Option<Uuid>) -> Result<(), StorageError> {
        self.edit(|document| {
            document.check_project(project)?;
            let moving: Vec<Uuid> = unique(ids)
                .into_iter()
                .filter(|id| document.groups.iter().any(|group| group.id == *id))
                .collect();
            if moving.is_empty() {
                return ids
                    .first()
                    .map_or(Ok(()), |&id| Err(StorageError::GroupNotFound { id }));
            }
            let mut names: Vec<ConnectionGroupName> = document
                .groups
                .iter()
                .filter(|group| place_of(group) == (None, project))
                .map(|group| group.name.clone())
                .collect();
            for id in &moving {
                let Some(group) = document.groups.iter().find(|group| group.id == *id) else {
                    continue;
                };
                if group.parent_id.is_some() {
                    return Err(StorageError::GroupNotTopLevel { id: group.id });
                }
                if group.project_id == project {
                    continue;
                }
                if names.iter().any(|name| name.same_name(&group.name)) {
                    return Err(StorageError::GroupNameTaken {
                        name: group.name.as_str().to_owned(),
                    });
                }
                names.push(group.name.clone());
            }
            for group in &mut document.groups {
                if moving.contains(&group.id) {
                    group.project_id = project;
                }
            }
            Ok(())
        })
    }
}

impl ConnectionsDocument {
    fn project_index(&self, id: Uuid) -> Result<usize, StorageError> {
        self.projects
            .iter()
            .position(|project| project.id == id)
            .ok_or(StorageError::ProjectNotFound { id })
    }

    pub(super) fn check_project(&self, project: Option<Uuid>) -> Result<(), StorageError> {
        project.map_or(Ok(()), |id| self.project_index(id).map(|_| ()))
    }

    fn check_project_name(&self, name: &ConnectionProjectName, except: Option<Uuid>) -> Result<(), StorageError> {
        if self
            .projects
            .iter()
            .any(|held| Some(held.id) != except && held.name.same_name(name))
        {
            return Err(StorageError::ProjectNameTaken {
                name: name.as_str().to_owned(),
            });
        }
        Ok(())
    }
}

pub(in crate::connections) struct Landing<'a> {
    // The file's project ids, each to the local project it stands for.
    pub projects: &'a HashMap<Uuid, Uuid>,
    // Where what the file files under no project goes.
    pub into: Option<Uuid>,
}

impl Landing<'_> {
    pub fn named(&self, project: Option<Uuid>) -> Option<Uuid> {
        project.and_then(|id| self.projects.get(&id).copied())
    }

    pub fn project(&self, project: Option<Uuid>) -> Option<Uuid> {
        self.named(project).or(self.into)
    }
}

// By id, then by name: the first in order when a sync left two projects of one name.
pub(in crate::connections) fn merge_projects(
    local: &mut Vec<ConnectionProject>,
    incoming: Vec<ConnectionProject>,
) -> HashMap<Uuid, Uuid> {
    // Maps rather than scans, so a crafted file of many projects cannot hold the store for minutes.
    let mut at: HashMap<Uuid, usize> = local
        .iter()
        .enumerate()
        .map(|(index, project)| (project.id, index))
        .collect();
    let mut named: HashMap<String, Vec<Uuid>> = HashMap::with_capacity(local.len());
    let mut in_order: Vec<&ConnectionProject> = local.iter().collect();
    in_order.sort_by_key(|project| project.order);
    for project in in_order {
        named.entry(project.name.key()).or_default().push(project.id);
    }
    let mut next = local
        .iter()
        .map(|project| project.order)
        .max()
        .map_or(0, |last| last.saturating_add(1));
    let mut same = HashMap::with_capacity(incoming.len());
    // Renames first, so a name one of them frees or takes decides the rest whatever order the file lists them in.
    let (known, mut unknown): (Vec<ConnectionProject>, Vec<ConnectionProject>) =
        incoming.into_iter().partition(|project| at.contains_key(&project.id));
    unknown.sort_by_key(|project| project.order);
    for project in known.into_iter().chain(unknown) {
        let key = project.name.key();
        if let Some(&index) = at.get(&project.id) {
            let held = &mut local[index];
            let free = named
                .get(&key)
                .is_none_or(|owners| owners.iter().all(|owner| *owner == project.id));
            if free {
                if let Some(owners) = named.get_mut(&held.name.key()) {
                    owners.retain(|owner| *owner != project.id);
                }
                named.entry(key).or_default().push(project.id);
                held.name = project.name;
            }
            held.color = project.color;
            held.icon = project.icon;
            same.insert(project.id, project.id);
        } else if let Some(&owner) = named.get(&key).and_then(|owners| owners.first()) {
            same.insert(project.id, owner);
        } else {
            at.insert(project.id, local.len());
            named.entry(key).or_default().push(project.id);
            same.insert(project.id, project.id);
            local.push(ConnectionProject { order: next, ..project });
            next = next.saturating_add(1);
        }
    }
    same
}
