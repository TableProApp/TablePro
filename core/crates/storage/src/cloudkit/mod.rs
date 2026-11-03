// CloudKit transport stays in the host; the core only maps record fields.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use uuid::Uuid;

use crate::{ConnectionGroup, ConnectionList, SavedConnection};

mod merge;
mod order;
mod values;

#[cfg(test)]
mod tests;

pub use merge::merged;

use order::{Sibling, reads_before, sort_orders};
use values::{
    color, color_value, favorite, favorite_value, group_name, icon, icon_value, id_value, name_order, record_id,
    sort_key,
};

// A `ConnectionGroup` record's fields. `None` is a field the record lacks.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudGroup {
    pub group_id: String,
    pub name: Option<String>,
    pub color: Option<String>,
    pub icon_name: Option<String>,
    pub parent_id: Option<String>,
    pub sort_order: Option<i64>,
}

// Names only break ordering ties; the host owns connection name edits.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudConnection {
    pub connection_id: String,
    pub name: Option<String>,
    pub group_id: Option<String>,
    pub sort_order: Option<i64>,
    pub is_favorite: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudRecords {
    pub groups: Vec<CloudGroup>,
    pub connections: Vec<CloudConnection>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudIds {
    pub groups: Vec<Uuid>,
    pub connections: Vec<Uuid>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloudPull {
    // Every library record this device held before the pull, as the server last gave it.
    pub base: CloudRecords,
    pub changed: CloudRecords,
    pub deleted: CloudIds,
    // Deleted on this device and not pushed yet.
    pub deleted_here: CloudIds,
    // The favourites' order to keep, when the library does not hold it yet.
    pub favorites_order: Option<Vec<Uuid>>,
}

// Unknown groups stay in the record cache for a newer reader to understand.
pub fn layout(list: &ConnectionList, records: &CloudRecords, favorites_order: &[Uuid]) -> ConnectionList {
    let groups = read_groups(&records.groups);
    let known: HashSet<Uuid> = groups.iter().map(|group| group.id).collect();
    let recorded = by_id(&records.connections, |record| &record.connection_id);

    let mut places: HashMap<Option<Uuid>, Vec<(Option<(i64, String)>, u32, Uuid)>> = HashMap::new();
    let mut favorites: HashSet<Uuid> = HashSet::new();
    for saved in list.connections.iter() {
        let record = recorded.get(&saved.id);
        let group = match record {
            Some(record) => record.group_id.as_deref().and_then(record_id),
            None => saved.group_id,
        }
        .filter(|id| known.contains(id));
        let key = record.map(|record| {
            let name = record.name.clone().unwrap_or_else(|| saved.name.clone());
            (sort_key(record.sort_order), name)
        });
        places.entry(group).or_default().push((key, saved.order, saved.id));
        let is_favorite = record.map_or_else(|| list.is_favorite(saved.id), |record| favorite(record.is_favorite));
        if is_favorite {
            favorites.insert(saved.id);
        }
    }

    let mut placed: HashMap<Uuid, (Option<Uuid>, u32)> = HashMap::new();
    for (group, mut members) in places {
        members.sort_by(|left, right| match (&left.0, &right.0) {
            (Some(l), Some(r)) => reads_before((l.0, &l.1, left.2), (r.0, &r.1, right.2)),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => (left.1, left.2).cmp(&(right.1, right.2)),
        });
        for ((_, _, id), rank) in members.into_iter().zip(0_u32..) {
            placed.insert(id, (group, rank));
        }
    }
    let connections: Vec<SavedConnection> = list
        .connections
        .iter()
        .map(|saved| {
            let (group_id, order) = placed.get(&saved.id).copied().unwrap_or((None, saved.order));
            SavedConnection {
                group_id,
                order,
                ..saved.clone()
            }
        })
        .collect();

    let favorites = favorites_in_order(&connections, &favorites, favorites_order);
    ConnectionList {
        connections: Arc::from(connections),
        groups: Arc::from(groups),
        tags: list.tags.clone(),
        favorites: Arc::from(favorites),
    }
}

// Preserve raw fields so reading alone never writes edits back to CloudKit.
pub fn records(list: &ConnectionList, base: &CloudRecords) -> CloudRecords {
    CloudRecords {
        groups: group_records(list, base),
        connections: connection_records(list, base),
    }
}

// The records a push sends: the new ones, and those with a field that differs from `base`.
pub fn edits(list: &ConnectionList, base: &CloudRecords) -> CloudRecords {
    let all = records(list, base);
    let base_groups = by_id(&base.groups, |record| &record.group_id);
    let base_connections = by_id(&base.connections, |record| &record.connection_id);
    CloudRecords {
        groups: all
            .groups
            .into_iter()
            .filter(|record| changed(&base_groups, &record.group_id, record))
            .collect(),
        connections: all
            .connections
            .into_iter()
            .filter(|record| changed(&base_connections, &record.connection_id, record))
            .collect(),
    }
}

fn changed<R: PartialEq>(base: &HashMap<Uuid, &R>, id: &str, record: &R) -> bool {
    record_id(id)
        .and_then(|id| base.get(&id))
        .is_none_or(|held| *held != record)
}

fn by_id<'a, R>(records: &'a [R], id: impl Fn(&R) -> &String) -> HashMap<Uuid, &'a R> {
    let mut found = HashMap::with_capacity(records.len());
    for record in records {
        if let Some(parsed) = record_id(id(record)) {
            found.entry(parsed).or_insert(record);
        }
    }
    found
}

// Invalid parents must not prevent the host from showing a group.
fn read_groups(records: &[CloudGroup]) -> Vec<ConnectionGroup> {
    let mut claimed = HashSet::with_capacity(records.len());
    let mut seen = HashSet::with_capacity(records.len());
    let mut read: Vec<(ConnectionGroup, i64)> = Vec::with_capacity(records.len());
    for record in records {
        let Some(id) = record_id(&record.group_id).filter(|id| claimed.insert(*id)) else {
            continue;
        };
        let Some(name) = group_name(record.name.as_deref()) else {
            continue;
        };
        seen.insert(id);
        let group = ConnectionGroup {
            id,
            name,
            parent_id: record.parent_id.as_deref().and_then(record_id),
            order: 0,
            color: color(record.color.as_deref()),
            icon: icon(record.icon_name.as_deref()),
        };
        read.push((group, sort_key(record.sort_order)));
    }
    let mut groups: Vec<ConnectionGroup> = read.iter().map(|(group, _)| group.clone()).collect();
    for group in &mut groups {
        if group
            .parent_id
            .is_some_and(|parent| parent == group.id || !seen.contains(&parent))
        {
            group.parent_id = None;
        }
    }
    let cyclic = crate::connections::cyclic(&groups);
    let mut siblings: HashMap<Option<Uuid>, Vec<(i64, usize)>> = HashMap::new();
    for (index, group) in groups.iter_mut().enumerate() {
        if cyclic.contains(&group.id) {
            group.parent_id = None;
        }
        siblings
            .entry(group.parent_id)
            .or_default()
            .push((read[index].1, index));
    }
    for mut members in siblings.into_values() {
        members.sort_by(|left, right| {
            let (l, r) = (&groups[left.1], &groups[right.1]);
            reads_before((left.0, l.name.as_str(), l.id), (right.0, r.name.as_str(), r.id))
        });
        for ((_, index), rank) in members.into_iter().zip(0_u32..) {
            groups[index].order = rank;
        }
    }
    groups
}

fn group_records(list: &ConnectionList, base: &CloudRecords) -> Vec<CloudGroup> {
    let held = by_id(&base.groups, |record| &record.group_id);
    let as_read: HashMap<Uuid, ConnectionGroup> = read_groups(&base.groups)
        .into_iter()
        .map(|group| (group.id, group))
        .collect();
    let tree = list.group_tree();
    let mut parents: Vec<Option<Uuid>> = vec![None];
    parents.extend(tree.walk().iter().map(|group| Some(group.id)));

    let mut written = Vec::with_capacity(list.groups.len());
    for parent in parents {
        let children = tree.children(parent);
        let siblings: Vec<Sibling<'_>> = children
            .iter()
            .map(|group| Sibling {
                id: group.id,
                name: group.name.as_str(),
                base: held
                    .get(&group.id)
                    .filter(|_| as_read.get(&group.id).is_some_and(|read| read.parent_id == parent))
                    .map(|record| record.sort_order),
            })
            .collect();
        for (group, sort_order) in children.into_iter().zip(sort_orders(&siblings)) {
            let record = held.get(&group.id).copied();
            let read = as_read.get(&group.id);
            written.push(CloudGroup {
                group_id: record.map_or_else(|| id_value(group.id), |record| record.group_id.clone()),
                name: match record {
                    Some(record) if group_name(record.name.as_deref()).as_ref() == Some(&group.name) => {
                        record.name.clone()
                    }
                    _ => Some(group.name.as_str().to_owned()),
                },
                color: match record {
                    Some(record) if color(record.color.as_deref()) == group.color => record.color.clone(),
                    _ => Some(color_value(group.color)),
                },
                icon_name: match record {
                    Some(record) if icon(record.icon_name.as_deref()) == group.icon => record.icon_name.clone(),
                    _ => icon_value(group.icon.as_ref()),
                },
                parent_id: match (record, read) {
                    (Some(record), Some(read)) if read.parent_id == group.parent_id => record.parent_id.clone(),
                    _ => group.parent_id.map(id_value),
                },
                sort_order,
            });
        }
    }
    written
}

fn connection_records(list: &ConnectionList, base: &CloudRecords) -> Vec<CloudConnection> {
    let held = by_id(&base.connections, |record| &record.connection_id);
    let known: HashSet<Uuid> = read_groups(&base.groups).iter().map(|group| group.id).collect();
    let group_as_read = |record: &CloudConnection| {
        record
            .group_id
            .as_deref()
            .and_then(record_id)
            .filter(|id| known.contains(id))
    };
    let mut groups: Vec<Option<Uuid>> = vec![None];
    groups.extend(list.group_tree().walk().iter().map(|group| Some(group.id)));

    let mut written = Vec::with_capacity(list.connections.len());
    for group in groups {
        let members = list.connections_in(group);
        let names: Vec<String> = members
            .iter()
            .map(|saved| {
                held.get(&saved.id)
                    .and_then(|record| record.name.clone())
                    .unwrap_or_else(|| saved.name.clone())
            })
            .collect();
        let siblings: Vec<Sibling<'_>> = members
            .iter()
            .zip(&names)
            .map(|(saved, name)| Sibling {
                id: saved.id,
                name,
                base: held
                    .get(&saved.id)
                    .filter(|record| group_as_read(record) == group)
                    .map(|record| record.sort_order),
            })
            .collect();
        for (saved, sort_order) in members.into_iter().zip(sort_orders(&siblings)) {
            let record = held.get(&saved.id).copied();
            let is_favorite = list.is_favorite(saved.id);
            written.push(CloudConnection {
                connection_id: record.map_or_else(|| id_value(saved.id), |record| record.connection_id.clone()),
                name: record.map_or_else(|| Some(saved.name.clone()), |record| record.name.clone()),
                group_id: match record {
                    Some(record) if group_as_read(record) == saved.group_id => record.group_id.clone(),
                    _ => saved.group_id.map(id_value),
                },
                sort_order,
                is_favorite: match record {
                    Some(record) if favorite(record.is_favorite) == is_favorite => record.is_favorite,
                    _ => Some(favorite_value(is_favorite)),
                },
            });
        }
    }
    written
}

fn favorites_in_order(connections: &[SavedConnection], favorites: &HashSet<Uuid>, order: &[Uuid]) -> Vec<Uuid> {
    let mut listed: HashSet<Uuid> = HashSet::with_capacity(favorites.len());
    let mut ordered: Vec<Uuid> = order
        .iter()
        .copied()
        .filter(|id| favorites.contains(id) && listed.insert(*id))
        .collect();
    let mut rest: Vec<&SavedConnection> = connections
        .iter()
        .filter(|saved| favorites.contains(&saved.id) && !listed.contains(&saved.id))
        .collect();
    rest.sort_by(|left, right| name_order((&left.name, left.id), (&right.name, right.id)));
    ordered.extend(rest.into_iter().map(|saved| saved.id));
    ordered
}
