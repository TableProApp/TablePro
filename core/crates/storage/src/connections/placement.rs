use std::collections::HashSet;

use uuid::Uuid;

use super::{ConnectionsDocument, SavedConnection};

impl ConnectionsDocument {
    // Places stay as stored, so siblings may share a number or skip one; a list reads them by number, then as filed.
    pub(super) fn tidy_library(&mut self) {
        let mut seen = HashSet::with_capacity(self.groups.len());
        self.groups.retain(|group| seen.insert(group.id));
        let saved = self.connection_ids();
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
