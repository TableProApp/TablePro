// Members a store has no place for, kept from the base (0054, Rules for both providers: unknown fields are kept and
// sent back unchanged). A store's model (`tablepro_records::schema::model`) names the wire members it holds; a newer
// build's member, or a format stamp no store keeps, rides on the base, so the device neither removes it on the server
// nor reads its absence as an edit.

use std::collections::BTreeMap;

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::schema::model::{MODELS, Model, Target};

struct Held {
    targets: Vec<&'static str>,
    // The store keeps unknown top-level members itself.
    unknown: bool,
}

fn held(kind: Kind) -> Option<Held> {
    if kind.is_create_once() {
        return None;
    }
    // A settings record's host keeps the category and its options; a format stamp the CloudKit projection writes, or
    // a member a newer build adds beside them, rides on the base.
    if kind.is_settings() {
        return Some(Held {
            targets: vec!["category", "options"],
            unknown: false,
        });
    }
    let model: &Model = MODELS.iter().find(|model| model.kind == kind)?;
    let mut targets = Vec::new();
    let mut unknown = false;
    for (_, target) in model.members {
        match target {
            Target::Wire(path) => targets.push(*path),
            Target::Kept => unknown = true,
            Target::Id | Target::DeviceOnly => {}
        }
    }
    // An object the model names with members of its own, as `ssh_config` with its fields, holds only those: a member
    // a newer build adds inside it rides on the base.
    let all = targets.clone();
    targets.retain(|target| !all.iter().any(|other| other.starts_with(&format!("{target}."))));
    Some(Held { targets, unknown })
}

// Whether the store keeps the member at `pointer` (RFC 6901). One it has no place for never reaches it, so a pull of it
// asks the person nothing: it rides on the base until a build that keeps it reads it.
pub fn holds(kind: Kind, pointer: &str) -> bool {
    let Some(held) = held(kind) else {
        return true;
    };
    let parts: Vec<&str> = pointer.split('/').skip(1).collect();
    let path = parts.join(".");
    let inside = |target: &str| {
        path == target || path.starts_with(&format!("{target}.")) || target.starts_with(&format!("{path}."))
    };
    held.targets.iter().any(|target| inside(target))
        || (held.unknown
            && !held
                .targets
                .iter()
                .any(|target| target.split('.').next() == parts.first().copied()))
}

// The store's copy with every member of `base` the store cannot hold put back where the copy lacks it. A kind whose
// store holds any member, or that has no base yet, is the copy as it is.
pub fn carried(kind: Kind, stored: &Value, base: Option<&Value>) -> Value {
    let (Some(held), Some(base)) = (held(kind), base) else {
        return stored.clone();
    };
    let mut out = stored.clone();
    carry(&held, base, &mut out, "");
    out
}

fn carry(held: &Held, base: &Value, out: &mut Value, prefix: &str) {
    match (base, out) {
        (Value::Object(base), Value::Object(out)) => carry_members(held, base, out, prefix),
        // A list of objects the model names members of, as `ssh_config.jump_hosts`: each entry the store kept takes
        // back what it could never hold of the same entry in the base. An entry the store dropped stays dropped.
        (Value::Array(base), Value::Array(out)) => {
            for entry in out.iter_mut() {
                if let Some(from) = same_entry(held, base, entry, prefix) {
                    carry(held, from, entry, prefix);
                }
            }
        }
        _ => {}
    }
}

// The base's copy of a list entry: the one entry with its `id`, or for an entry with none, the one id-less entry
// whose members the store holds are all the same. An entry that matches none, or more than one, takes nothing, so a
// member is never carried onto another entry.
fn same_entry<'a>(held: &Held, base: &'a [Value], entry: &Value, prefix: &str) -> Option<&'a Value> {
    let mut found = base.iter().filter(|candidate| match entry.get("id") {
        Some(id) => candidate.get("id") == Some(id),
        None => candidate.get("id").is_none() && held_part(held, candidate, prefix) == held_part(held, entry, prefix),
    });
    match (found.next(), found.next()) {
        (Some(one), None) => Some(one),
        _ => None,
    }
}

// The members of a list entry the store holds.
fn held_part<'a>(held: &Held, entry: &'a Value, prefix: &str) -> BTreeMap<&'a String, &'a Value> {
    entry.as_object().map_or_else(BTreeMap::new, |members| {
        members
            .iter()
            .filter(|(name, _)| {
                let path = format!("{prefix}.{name}");
                held.targets
                    .iter()
                    .any(|target| *target == path || target.starts_with(&format!("{path}.")))
            })
            .collect()
    })
}

fn carry_members(
    held: &Held,
    base: &serde_json::Map<String, Value>,
    out: &mut serde_json::Map<String, Value>,
    prefix: &str,
) {
    for (name, value) in base {
        let path = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}.{name}")
        };
        if held.targets.contains(&path.as_str()) {
            continue;
        }
        let inner = format!("{path}.");
        if held.targets.iter().any(|target| target.starts_with(&inner)) {
            // An object the store lacks keeps only what the store could never have held of it, so a removal here
            // still removes what the store holds.
            let absent = !out.contains_key(name);
            let nested = out
                .entry(name.clone())
                .or_insert_with(|| Value::Object(serde_json::Map::new()));
            carry(held, value, nested, &path);
            if absent && matches!(nested, Value::Object(members) if members.is_empty()) {
                out.remove(name);
            }
            continue;
        }
        if prefix.is_empty() && held.unknown {
            continue;
        }
        out.entry(name.clone()).or_insert_with(|| value.clone());
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_member_the_group_store_has_no_place_for_rides_on_the_base() {
        let base = json!({"name": "Prod", "schema_version": 2, "future": {"x": 1}});
        let stored = json!({"name": "Prod 2"});

        assert_eq!(
            carried(Kind::Group, &stored, Some(&base)),
            json!({"name": "Prod 2", "schema_version": 2, "future": {"x": 1}})
        );
    }

    #[test]
    fn a_held_member_the_store_removed_stays_removed() {
        let base = json!({"name": "Prod", "color": "Red"});
        let stored = json!({"name": "Prod"});

        assert_eq!(carried(Kind::Group, &stored, Some(&base)), stored);
    }

    #[test]
    fn a_connection_keeps_top_level_unknowns_itself_but_not_nested_ones() {
        let base = json!({
            "name": "Prod",
            "future": 1,
            "ssh_config": {"host": "bastion", "future_nested": true},
        });
        let stored = json!({"name": "Prod", "ssh_config": {"host": "bastion"}});

        assert_eq!(
            carried(Kind::Connection, &stored, Some(&base)),
            json!({"name": "Prod", "ssh_config": {"host": "bastion", "future_nested": true}})
        );
    }

    #[test]
    fn an_object_the_store_removed_keeps_only_what_the_store_never_held_of_it() {
        let base = json!({"name": "Prod", "ssh_config": {"host": "bastion", "future_nested": true}});
        let gone = json!({"name": "Prod", "ssh_config": {"host": "bastion"}});
        let stored = json!({"name": "Prod"});

        assert_eq!(
            carried(Kind::Connection, &stored, Some(&base)),
            json!({"name": "Prod", "ssh_config": {"future_nested": true}})
        );
        assert_eq!(carried(Kind::Connection, &stored, Some(&gone)), stored);
    }

    #[test]
    fn each_jump_host_the_store_kept_takes_back_what_a_newer_build_wrote_inside_it() {
        let base = json!({
            "name": "Prod",
            "ssh_config": {"jump_hosts": [
                {"id": "j1", "host": "a", "future": 1},
                {"id": "j2", "host": "b", "future": 2},
                {"id": "j3", "host": "c", "future": 3},
            ]},
        });
        let stored = json!({
            "name": "Prod",
            "ssh_config": {"jump_hosts": [{"id": "j2", "host": "b2"}, {"id": "j1", "host": "a"}]},
        });

        assert_eq!(
            carried(Kind::Connection, &stored, Some(&base)),
            json!({
                "name": "Prod",
                "ssh_config": {"jump_hosts": [
                    {"id": "j2", "host": "b2", "future": 2},
                    {"id": "j1", "host": "a", "future": 1},
                ]},
            })
        );
        let unnamed = json!({"name": "Hop", "jump_hosts": [
            {"host": "a", "future": 1},
            {"host": "b", "future": 2},
            {"host": "b", "port": 22, "future": 3},
            {"host": "c", "future": 4},
            {"host": "c", "future": 5},
        ]});
        let edited = json!({"name": "Hop", "jump_hosts": [
            {"host": "b"},
            {"host": "a2"},
            {"host": "c"},
            {"host": "b", "port": 22},
        ]});
        assert_eq!(
            carried(Kind::SshProfile, &edited, Some(&unnamed)),
            json!({"name": "Hop", "jump_hosts": [
                {"host": "b", "future": 2},
                {"host": "a2"},
                {"host": "c"},
                {"host": "b", "port": 22, "future": 3},
            ]})
        );
        let profile = json!({"name": "Hop", "jump_hosts": [{"id": "j1", "host": "a", "future": true}]});
        let kept = json!({"name": "Hop", "jump_hosts": [{"id": "j1", "host": "a"}]});
        assert_eq!(carried(Kind::SshProfile, &kept, Some(&profile)), profile);
        let gone = json!({"name": "Hop"});
        assert_eq!(carried(Kind::SshProfile, &gone, Some(&profile)), gone);
    }

    #[test]
    fn a_store_holds_its_model_members_and_a_connection_its_unknown_top_level_ones() {
        assert!(holds(Kind::SavedQuery, "/query"));
        assert!(!holds(Kind::SavedQuery, "/sql"));
        assert!(holds(Kind::Connection, "/ssh_config/host"));
        assert!(holds(Kind::Connection, "/future"));
        assert!(!holds(Kind::Connection, "/ssh_config/future"));
        assert!(holds(Kind::Connection, "/additional_fields/useSSL"));
        assert!(holds(Kind::MacosSettings, "/options/anything"));
        assert!(!holds(Kind::MacosSettings, "/schema_version"));
    }

    #[test]
    fn a_settings_record_carries_what_beside_its_options_the_host_does_not_keep() {
        let base = json!({"category": "general", "options": {}, "schema_version": 1});
        let stored = json!({"category": "general", "options": {}});

        assert_eq!(carried(Kind::MacosSettings, &stored, Some(&base)), base);
        assert_eq!(carried(Kind::HistoryEntry, &stored, Some(&base)), stored);
    }
}
