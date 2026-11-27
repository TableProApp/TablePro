use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use uuid::Uuid;

use super::{ConnectionList, ConnectionsDocument, SavedConnection};
use crate::{ConnectionGroup, ConnectionProject};

// The top-level group decides for its subtree; an id no project holds reads as no project (core ADR 0067).
#[derive(Debug, Clone, Default)]
pub struct ProjectMembership {
    groups: HashMap<Uuid, Option<Uuid>>,
    projects: HashSet<Uuid>,
}

impl ProjectMembership {
    pub fn new(groups: &[ConnectionGroup], projects: &[ConnectionProject]) -> Self {
        let known: HashSet<Uuid> = projects.iter().map(|project| project.id).collect();
        let mut at: HashMap<Uuid, &ConnectionGroup> = HashMap::with_capacity(groups.len());
        for group in groups {
            at.entry(group.id).or_insert(group);
        }
        let mut found: HashMap<Uuid, Option<Uuid>> = HashMap::with_capacity(groups.len());
        for group in groups {
            let mut path = vec![group.id];
            let mut seen = HashSet::from([group.id]);
            let mut top = group;
            let mut settled = None;
            while let Some(parent) = top.parent_id.and_then(|id| at.get(&id).copied()) {
                if let Some(project) = found.get(&parent.id) {
                    settled = Some(*project);
                    break;
                }
                // A cycle built by hand has no top, so it is in no project.
                if !seen.insert(parent.id) {
                    settled = Some(None);
                    break;
                }
                path.push(parent.id);
                top = parent;
            }
            let project = settled.unwrap_or_else(|| top.project_id.filter(|id| known.contains(id)));
            for id in path {
                found.entry(id).or_insert(project);
            }
        }
        Self {
            groups: found,
            projects: known,
        }
    }

    pub fn of_group(&self, group: Uuid) -> Option<Uuid> {
        self.groups.get(&group).copied().flatten()
    }

    pub fn of_connection(&self, connection: &SavedConnection) -> Option<Uuid> {
        match connection.group_id {
            Some(group) if self.groups.contains_key(&group) => self.of_group(group),
            _ => connection.project_id.filter(|id| self.projects.contains(id)),
        }
    }

    pub fn holds(&self, project: Uuid) -> bool {
        self.projects.contains(&project)
    }
}

impl ConnectionList {
    pub fn project(&self, id: Uuid) -> Option<&ConnectionProject> {
        self.projects.iter().find(|project| project.id == id)
    }

    pub fn projects_in_order(&self) -> Vec<&ConnectionProject> {
        let mut ordered: Vec<&ConnectionProject> = self.projects.iter().collect();
        ordered.sort_by_key(|project| project.order);
        ordered
    }

    pub fn membership(&self) -> ProjectMembership {
        ProjectMembership::new(&self.groups, &self.projects)
    }

    // Builds the membership each call: take `membership()` once for many connections.
    pub fn effective_project(&self, connection: &SavedConnection) -> Option<Uuid> {
        self.membership().of_connection(connection)
    }

    pub fn effective_group_project(&self, group: Uuid) -> Option<Uuid> {
        self.membership().of_group(group)
    }

    // `None` is All Connections, also for a deleted project a setting still names.
    pub fn resolved_scope(&self, project: Option<Uuid>) -> Option<Uuid> {
        project.filter(|id| self.projects.iter().any(|held| held.id == *id))
    }

    // Empty groups stay, since a group belongs to its project; tags and projects are shared.
    #[must_use]
    pub fn scoped(&self, project: Option<Uuid>) -> ConnectionList {
        let Some(project) = self.resolved_scope(project) else {
            return self.clone();
        };
        let membership = self.membership();
        let connections: Vec<SavedConnection> = self
            .connections
            .iter()
            .filter(|connection| membership.of_connection(connection) == Some(project))
            .cloned()
            .collect();
        let groups: Vec<ConnectionGroup> = self
            .groups
            .iter()
            .filter(|group| membership.of_group(group.id) == Some(project))
            .cloned()
            .collect();
        let members: HashSet<Uuid> = connections.iter().map(|connection| connection.id).collect();
        let favorites: Vec<Uuid> = self
            .favorites
            .iter()
            .copied()
            .filter(|id| members.contains(id))
            .collect();
        ConnectionList {
            connections: Arc::from(connections),
            groups: Arc::from(groups),
            tags: self.tags.clone(),
            favorites: Arc::from(favorites),
            ..self.clone()
        }
    }
}

impl ConnectionsDocument {
    pub(super) fn membership(&self) -> ProjectMembership {
        ProjectMembership::new(&self.groups, &self.projects)
    }

    // Local changes only: a pull has no order, so it must not settle who is in which project.
    pub(super) fn keep_membership(&mut self, before: &ConnectionsDocument) {
        let was = before.membership();
        let old_groups: HashMap<Uuid, &ConnectionGroup> = before.groups.iter().map(|group| (group.id, group)).collect();
        for group in &mut self.groups {
            if group.parent_id.is_some() {
                group.project_id = None;
            } else if let Some(old) = old_groups.get(&group.id)
                && old.parent_id.is_some()
                && group.project_id == old.project_id
            {
                group.project_id = was.of_group(group.id);
            }
        }
        let old_connections: HashMap<Uuid, &SavedConnection> = before
            .connections
            .iter()
            .map(|connection| (connection.id, connection))
            .collect();
        for connection in &mut self.connections {
            if connection.group_id.is_some() {
                connection.project_id = None;
            } else if let Some(old) = old_connections.get(&connection.id)
                && old.group_id.is_some()
                && connection.project_id == old.project_id
            {
                connection.project_id = was.of_connection(old);
            }
        }
    }

    // A pull that deletes a group leaves its members at the top with no project of their own, so
    // they keep the one the group gave them. Nothing else a pull brings is settled here.
    pub(super) fn keep_membership_of_released(&mut self, before: &ConnectionsDocument) {
        let was = before.membership();
        let kept: HashSet<Uuid> = self.groups.iter().map(|group| group.id).collect();
        let old_groups: HashMap<Uuid, &ConnectionGroup> = before.groups.iter().map(|group| (group.id, group)).collect();
        for group in &mut self.groups {
            let Some(old) = old_groups.get(&group.id) else { continue };
            let released = old.parent_id.is_some_and(|parent| !kept.contains(&parent));
            if released && group.parent_id.is_none() && group.project_id == old.project_id {
                group.project_id = was.of_group(group.id);
            }
        }
        let old_connections: HashMap<Uuid, &SavedConnection> = before
            .connections
            .iter()
            .map(|connection| (connection.id, connection))
            .collect();
        for connection in &mut self.connections {
            let Some(old) = old_connections.get(&connection.id) else {
                continue;
            };
            let released = old.group_id.is_some_and(|group| !kept.contains(&group));
            if released && connection.group_id.is_none() && connection.project_id == old.project_id {
                connection.project_id = was.of_connection(old);
            }
        }
    }
}
