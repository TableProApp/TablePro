use std::collections::{HashMap, HashSet};

use tablepro_storage::ConnectionList;
use uuid::Uuid;

use super::values::record_id;
use super::{CloudConnection, CloudGroup, CloudPull, CloudRecords, records};
use crate::cycles::keep_server_parents;

// Rebase local field edits over the pull, matching the host's push conflict handling.
pub fn merged(list: &ConnectionList, pull: &CloudPull) -> CloudRecords {
    let local = records(list, &pull.base);
    let mut groups = merge(
        Side {
            base: &pull.base.groups,
            local: &local.groups,
            changed: &pull.changed.groups,
        },
        &pull.deleted.groups,
        &pull.deleted_here.groups,
        |record| &record.group_id,
        |base, local, server| CloudGroup {
            group_id: server.group_id.clone(),
            name: pick(&base.name, &local.name, &server.name),
            color: pick(&base.color, &local.color, &server.color),
            icon_name: pick(&base.icon_name, &local.icon_name, &server.icon_name),
            parent_id: pick(&base.parent_id, &local.parent_id, &server.parent_id),
            sort_order: pick(&base.sort_order, &local.sort_order, &server.sort_order),
        },
    );
    yield_cycles(&mut groups, pull, &local.groups);
    CloudRecords {
        groups,
        connections: merge(
            Side {
                base: &pull.base.connections,
                local: &local.connections,
                changed: &pull.changed.connections,
            },
            &pull.deleted.connections,
            &pull.deleted_here.connections,
            |record| &record.connection_id,
            |base, local, server| CloudConnection {
                connection_id: server.connection_id.clone(),
                name: server.name.clone(),
                group_id: pick(&base.group_id, &local.group_id, &server.group_id),
                sort_order: pick(&base.sort_order, &local.sort_order, &server.sort_order),
                is_favorite: pick(&base.is_favorite, &local.is_favorite, &server.is_favorite),
            },
        ),
    }
}

// Yield conflicting local moves so normalizing a cycle cannot undo a remote move.
fn yield_cycles(groups: &mut [CloudGroup], pull: &CloudPull, local: &[CloudGroup]) {
    let keyed = |records: &[CloudGroup]| -> HashMap<Uuid, CloudGroup> {
        records
            .iter()
            .filter_map(|record| record_id(&record.group_id).map(|id| (id, record.clone())))
            .collect()
    };
    let base = keyed(&pull.base.groups);
    let mut server = base.clone();
    server.extend(keyed(&pull.changed.groups));
    let moved_here: HashSet<Uuid> = keyed(local)
        .into_iter()
        .filter(|(id, record)| base.get(id).is_some_and(|held| held.parent_id != record.parent_id))
        .map(|(id, _)| id)
        .collect();
    let mut parents: HashMap<Uuid, Option<Uuid>> = groups
        .iter()
        .filter_map(|group| {
            Some((
                record_id(&group.group_id)?,
                group.parent_id.as_deref().and_then(record_id),
            ))
        })
        .collect();
    let theirs: HashMap<Uuid, Option<Uuid>> = server
        .iter()
        .map(|(id, record)| (*id, record.parent_id.as_deref().and_then(record_id)))
        .collect();
    let yielded = keep_server_parents(&mut parents, &theirs, &moved_here);
    for group in groups.iter_mut() {
        if record_id(&group.group_id).is_some_and(|id| yielded.contains(&id)) {
            group.parent_id = record_id(&group.group_id)
                .and_then(|id| server.get(&id))
                .and_then(|record| record.parent_id.clone());
        }
    }
}

struct Side<'a, R> {
    base: &'a [R],
    local: &'a [R],
    changed: &'a [R],
}

fn pick<T: Clone + PartialEq>(base: &T, local: &T, server: &T) -> T {
    if local == base { server.clone() } else { local.clone() }
}

fn merge<R: Clone>(
    side: Side<'_, R>,
    deleted: &[Uuid],
    deleted_here: &[Uuid],
    id: impl Fn(&R) -> &String,
    fields: impl Fn(&R, &R, &R) -> R,
) -> Vec<R> {
    let deleted: HashSet<&Uuid> = deleted.iter().chain(deleted_here).collect();
    let mut server: Vec<R> = Vec::with_capacity(side.base.len() + side.changed.len());
    let mut at: HashMap<Uuid, usize> = HashMap::with_capacity(server.capacity());
    for record in side.base.iter().chain(side.changed) {
        let Some(key) = record_id(id(record)) else {
            continue;
        };
        match at.get(&key) {
            Some(&index) => server[index] = record.clone(),
            None => {
                at.insert(key, server.len());
                server.push(record.clone());
            }
        }
    }
    let base: HashMap<Uuid, &R> = side
        .base
        .iter()
        .filter_map(|record| record_id(id(record)).map(|key| (key, record)))
        .collect();
    for record in side.local {
        let Some(key) = record_id(id(record)) else {
            continue;
        };
        match (base.get(&key), at.get(&key)) {
            (Some(held), Some(&index)) => server[index] = fields(held, record, &server[index]),
            (None, Some(_)) => {}
            (_, None) => {
                at.insert(key, server.len());
                server.push(record.clone());
            }
        }
    }
    server
        .into_iter()
        .filter(|record| record_id(id(record)).is_none_or(|key| !deleted.contains(&key)))
        .collect()
}
