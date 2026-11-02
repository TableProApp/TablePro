use std::collections::HashMap;
use std::collections::hash_map::Entry;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::{ConnectionGroup, ConnectionGroupName};

#[derive(Deserialize)]
struct FiledByNameList {
    connections: Vec<FiledByName>,
    #[serde(flatten)]
    rest: Value,
}

#[derive(Deserialize)]
struct FiledByName {
    #[serde(default)]
    group: Option<String>,
    #[serde(flatten)]
    rest: Value,
}

#[derive(Serialize)]
struct FiledByIdList {
    connections: Vec<FiledById>,
    groups: Vec<ConnectionGroup>,
    #[serde(flatten)]
    rest: Value,
}

#[derive(Serialize)]
struct FiledById {
    #[serde(skip_serializing_if = "Option::is_none")]
    group_id: Option<Uuid>,
    order: u32,
    #[serde(flatten)]
    rest: Value,
}

/// Version 2 filed a connection under a group name. Groups, and each
/// group's connections, are numbered by name, the order the Linux app
/// listed them in.
pub(super) fn group_names_to_groups(document: Value) -> Result<Value, String> {
    let list: FiledByNameList = serde_json::from_value(document).map_err(|error| error.to_string())?;
    let mut groups: Vec<ConnectionGroup> = Vec::new();
    let mut named: HashMap<String, Uuid> = HashMap::new();
    let mut connections: Vec<FiledById> = Vec::with_capacity(list.connections.len());
    for connection in list.connections {
        let group_id = connection
            .group
            .as_deref()
            .and_then(ConnectionGroupName::from_stored)
            .map(|name| match named.entry(name.as_str().to_owned()) {
                Entry::Occupied(held) => *held.get(),
                Entry::Vacant(free) => {
                    let group = ConnectionGroup::legacy(name);
                    groups.push(group.clone());
                    *free.insert(group.id)
                }
            });
        connections.push(FiledById {
            group_id,
            order: 0,
            rest: connection.rest,
        });
    }
    let group_ranks = ranks(groups.iter().map(|group| group.name.as_str().to_owned()).collect());
    for (group, rank) in groups.iter_mut().zip(group_ranks) {
        group.order = rank;
    }
    number_connections(&mut connections);
    serde_json::to_value(FiledByIdList {
        connections,
        groups,
        rest: list.rest,
    })
    .map_err(|error| error.to_string())
}

fn number_connections(connections: &mut [FiledById]) {
    let mut by_group: HashMap<Option<Uuid>, Vec<usize>> = HashMap::new();
    for (index, connection) in connections.iter().enumerate() {
        by_group.entry(connection.group_id).or_default().push(index);
    }
    for members in by_group.into_values() {
        let names = members
            .iter()
            .map(|index| {
                connections[*index]
                    .rest
                    .get("name")
                    .and_then(Value::as_str)
                    .map(crate::name_rules::shown)
                    .unwrap_or_default()
            })
            .collect();
        for (index, rank) in members.into_iter().zip(ranks(names)) {
            connections[index].order = rank;
        }
    }
}

fn ranks(names: Vec<String>) -> Vec<u32> {
    let mut sorted: Vec<(String, String, usize)> = names
        .into_iter()
        .enumerate()
        .map(|(index, name)| (name.to_lowercase(), name, index))
        .collect();
    sorted.sort();
    let mut ranks = vec![0; sorted.len()];
    for (rank, (_, _, index)) in sorted.into_iter().enumerate() {
        ranks[index] = u32::try_from(rank).unwrap_or(u32::MAX);
    }
    ranks
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(text: &str) -> Value {
        serde_json::from_str(text).expect("JSON")
    }

    fn upgraded(connections: &str) -> Value {
        group_names_to_groups(value(&format!(
            r#"{{"version": 2, "connections": {connections}, "tags": []}}"#
        )))
        .expect("upgraded")
    }

    #[test]
    fn identical_names_share_one_group_and_others_get_their_own() {
        let document = upgraded(
            r#"[
                {"name": "b", "group": "Work"},
                {"name": "a", "group": " Work "},
                {"name": "c", "group": "work"},
                {"name": "d"},
                {"name": "e", "group": "  "},
                {"name": "f", "group": null}
            ]"#,
        );

        let work = ConnectionGroup::legacy(ConnectionGroupName::new("Work").expect("a name"));
        let lower = ConnectionGroup::legacy(ConnectionGroupName::new("work").expect("a name"));
        assert_eq!(
            document["groups"],
            value(&format!(
                r#"[{{"id": "{}", "name": "Work", "order": 0}}, {{"id": "{}", "name": "work", "order": 1}}]"#,
                work.id, lower.id
            ))
        );
        let filed: Vec<(String, Option<String>, u64)> = (0..6)
            .map(|at| {
                let connection = &document["connections"][at];
                (
                    connection["name"].as_str().unwrap_or_default().to_owned(),
                    connection["group_id"].as_str().map(str::to_owned),
                    connection["order"].as_u64().unwrap_or(u64::MAX),
                )
            })
            .collect();
        let (work, lower) = (Some(work.id.to_string()), Some(lower.id.to_string()));
        assert_eq!(
            filed,
            [
                ("b".to_owned(), work.clone(), 1),
                ("a".to_owned(), work, 0),
                ("c".to_owned(), lower, 0),
                ("d".to_owned(), None, 0),
                ("e".to_owned(), None, 1),
                ("f".to_owned(), None, 2),
            ]
        );
        assert_eq!(document["version"], 2, "the version is the caller's to read");
        assert_eq!(document["tags"], value("[]"));
        assert!(document["connections"][0].get("group").is_none());
    }

    #[test]
    fn a_name_too_long_or_with_control_characters_is_cleaned_first() {
        let long = "g".repeat(ConnectionGroupName::MAX_CHARS + 5);
        let document = upgraded(&format!(
            r#"[{{"name": "a", "group": "{long}"}}, {{"name": "b", "group": "Work\tHome"}}]"#
        ));

        let names: Vec<&str> = (0..2)
            .map(|at| document["groups"][at]["name"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(
            names,
            ["g".repeat(ConnectionGroupName::MAX_CHARS).as_str(), "Work Home"]
        );
    }

    #[test]
    fn a_group_that_is_not_a_name_fails_the_step() {
        let failed = group_names_to_groups(value(r#"{"version": 2, "connections": [{"name": "a", "group": 5}]}"#));

        assert!(failed.is_err());
    }

    #[test]
    fn names_rank_in_any_case_then_exactly() {
        assert_eq!(
            ranks(vec!["b".into(), "B".into(), "a".into(), "b".into()]),
            [2, 1, 0, 3]
        );
    }
}
