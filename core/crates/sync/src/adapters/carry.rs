// Members a store has no place for, kept from the base (0054, Rules for both providers: unknown fields are kept and
// sent back unchanged). A store's model (`tablepro_records::schema::model`) names the wire members it holds; a newer
// build's member, or a format stamp no store keeps, rides on the base, so the device neither removes it on the server
// nor reads its absence as an edit.

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
    let (Some(base), Some(out)) = (base.as_object(), out.as_object_mut()) else {
        return;
    };
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
            // Only into an object the store still holds: one it lacks was removed here.
            if let Some(nested) = out.get_mut(name) {
                carry(held, value, nested, &path);
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
    fn nothing_is_carried_into_an_object_the_store_removed() {
        let base = json!({"name": "Prod", "ssh_config": {"host": "bastion", "future_nested": true}});
        let stored = json!({"name": "Prod"});

        assert_eq!(carried(Kind::Connection, &stored, Some(&base)), stored);
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
    }

    #[test]
    fn settings_and_history_carry_nothing() {
        let base = json!({"category": "general", "options": {}, "schema_version": 1});
        let stored = json!({"category": "general", "options": {}});

        assert_eq!(carried(Kind::MacosSettings, &stored, Some(&base)), stored);
        assert_eq!(carried(Kind::HistoryEntry, &stored, Some(&base)), stored);
    }
}
