use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use super::{ConnectionsDocument, SavedConnection};
use crate::ConnectionGroup;

impl ConnectionsDocument {
    // Every read and write passes here, so a hand-edited or crafted file
    // cannot bring a cycle, a stray id or two items in one place.
    pub(super) fn tidy_library(&mut self) {
        let mut seen = HashSet::with_capacity(self.groups.len());
        self.groups.retain(|group| seen.insert(group.id));
        for group in &mut self.groups {
            if group
                .parent_id
                .is_some_and(|parent| parent == group.id || !seen.contains(&parent))
            {
                group.parent_id = None;
            }
        }
        // Rooted, as the macOS library repairs one.
        let cyclic = cyclic(&self.groups);
        for group in &mut self.groups {
            if cyclic.contains(&group.id) {
                group.parent_id = None;
            }
        }
        renumber(
            &mut self.groups,
            |group| (group.parent_id, group.order),
            |group, order| {
                group.order = order;
            },
        );
        for connection in &mut self.connections {
            if connection.group_id.is_some_and(|id| !seen.contains(&id)) {
                connection.group_id = None;
            }
        }
        renumber(
            &mut self.connections,
            |connection| (connection.group_id, connection.order),
            |connection, order| connection.order = order,
        );
        let saved: HashSet<Uuid> = self.connections.iter().map(|connection| connection.id).collect();
        let mut listed = HashSet::with_capacity(self.favorites.len());
        self.favorites.retain(|id| saved.contains(id) && listed.insert(*id));
    }

    /// `kept` is the group and place the entry had, which it keeps when
    /// it stays in that group.
    pub(super) fn settle_place(&self, connection: &mut SavedConnection, kept: Option<(Option<Uuid>, u32)>) {
        if connection
            .group_id
            .is_some_and(|id| !self.groups.iter().any(|group| group.id == id))
        {
            connection.group_id = None;
        }
        connection.order = match kept {
            Some((group, order)) if group == connection.group_id => order,
            _ => self.next_connection_order(connection.group_id),
        };
    }

    pub(super) fn next_connection_order(&self, group: Option<Uuid>) -> u32 {
        next_order(&self.connections, group)
    }

    pub(super) fn next_group_order(&self, parent: Option<Uuid>) -> u32 {
        next(
            self.groups
                .iter()
                .filter(|group| group.parent_id == parent)
                .map(|group| group.order),
        )
    }
}

pub(super) fn next_order(connections: &[SavedConnection], group: Option<Uuid>) -> u32 {
    next(
        connections
            .iter()
            .filter(|connection| connection.group_id == group)
            .map(|connection| connection.order),
    )
}

fn next(orders: impl Iterator<Item = u32>) -> u32 {
    orders.max().map_or(0, |last| last.saturating_add(1))
}

/// `moving` goes last when `before` is not among the rest.
pub(super) fn placed(ordered: &[Uuid], moving: &[Uuid], before: Option<Uuid>) -> Vec<Uuid> {
    let leaving: HashSet<&Uuid> = moving.iter().collect();
    let mut rest: Vec<Uuid> = ordered.iter().filter(|id| !leaving.contains(id)).copied().collect();
    let at = before
        .and_then(|before| rest.iter().position(|id| *id == before))
        .unwrap_or(rest.len());
    rest.splice(at..at, moving.iter().copied());
    rest
}

pub(super) fn unique(ids: &[Uuid]) -> Vec<Uuid> {
    let mut seen = HashSet::with_capacity(ids.len());
    ids.iter().copied().filter(|id| seen.insert(*id)).collect()
}

fn cyclic(groups: &[ConnectionGroup]) -> HashSet<Uuid> {
    let parents: HashMap<Uuid, Option<Uuid>> = groups.iter().map(|group| (group.id, group.parent_id)).collect();
    let mut cyclic = HashSet::new();
    let mut settled = HashSet::new();
    for group in groups {
        let mut path: Vec<Uuid> = Vec::new();
        let mut on_path: HashMap<Uuid, usize> = HashMap::new();
        let mut current = Some(group.id);
        while let Some(id) = current {
            if settled.contains(&id) || cyclic.contains(&id) {
                break;
            }
            if let Some(&start) = on_path.get(&id) {
                cyclic.extend(path[start..].iter().copied());
                break;
            }
            on_path.insert(id, path.len());
            path.push(id);
            current = parents.get(&id).copied().flatten();
        }
        settled.extend(path.into_iter().filter(|id| !cyclic.contains(id)));
    }
    cyclic
}

fn renumber<T>(items: &mut [T], place: impl Fn(&T) -> (Option<Uuid>, u32), set: impl Fn(&mut T, u32)) {
    let mut places: HashMap<Option<Uuid>, Vec<(u32, usize)>> = HashMap::new();
    for (index, item) in items.iter().enumerate() {
        let (at, order) = place(item);
        places.entry(at).or_default().push((order, index));
    }
    for mut members in places.into_values() {
        members.sort_unstable();
        for (rank, (_, index)) in members.into_iter().enumerate() {
            set(&mut items[index], u32::try_from(rank).unwrap_or(u32::MAX));
        }
    }
}
