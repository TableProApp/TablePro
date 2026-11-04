use std::collections::HashSet;

use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

use crate::{ConnectionColor, ConnectionTagName};

/// A label several connections can share. Connections name it by id, so
/// a rename or a new colour reaches every one of them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "StoredTag")]
pub struct ConnectionTag {
    pub id: Uuid,
    pub name: ConnectionTagName,
    pub color: ConnectionColor,
}

#[derive(Deserialize)]
struct StoredTag {
    id: Uuid,
    name: String,
    color: ConnectionColor,
}

impl TryFrom<StoredTag> for ConnectionTag {
    type Error = crate::TagNameError;

    fn try_from(stored: StoredTag) -> Result<Self, Self::Error> {
        Ok(Self {
            id: stored.id,
            name: ConnectionTagName::from_stored(&stored.name, stored.id)?,
            color: stored.color,
        })
    }
}

pub(crate) fn deserialize_list<'de, D>(deserializer: D) -> Result<Vec<ConnectionTag>, D::Error>
where
    D: Deserializer<'de>,
{
    let stored = Vec::<StoredTag>::deserialize(deserializer)?;
    let mut recovered = Vec::new();
    let mut held = HashSet::new();
    let mut tags = Vec::with_capacity(stored.len());
    for (index, raw) in stored.into_iter().enumerate() {
        let recover = crate::name_rules::shown(&raw.name).is_empty();
        let tag = ConnectionTag::try_from(raw).map_err(serde::de::Error::custom)?;
        if recover {
            recovered.push(index);
        } else {
            held.insert(tag.name.key());
        }
        tags.push(tag);
    }
    // Reserve visible names before any recovery, regardless of file order.
    recovered.sort_unstable_by_key(|&index| tags[index].id);
    for index in recovered {
        let tag = &mut tags[index];
        let name = crate::name_rules::claim_recovered(tag.name.as_str(), Some(ConnectionTagName::MAX_CHARS), &mut held);
        tag.name = ConnectionTagName::new(&name).map_err(serde::de::Error::custom)?;
    }
    Ok(tags)
}

impl ConnectionTag {
    pub fn new(name: ConnectionTagName, color: ConnectionColor) -> Self {
        Self {
            id: Uuid::new_v4(),
            name,
            color,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tag_is_stored_with_its_id_name_and_colour() {
        let tag = ConnectionTag::new(ConnectionTagName::new("acme").expect("a name"), ConnectionColor::Teal);

        let json = serde_json::to_value(&tag).expect("serialize");

        assert_eq!(json["id"], tag.id.to_string());
        assert_eq!(json["name"], "acme");
        assert_eq!(json["color"], "teal");
        assert_eq!(serde_json::from_value::<ConnectionTag>(json).expect("deserialize"), tag);
    }

    #[test]
    fn a_tag_without_a_colour_is_refused() {
        let json = r#"{"id":"550e8400-e29b-41d4-a716-446655440000","name":"acme"}"#;

        assert!(serde_json::from_str::<ConnectionTag>(json).is_err());
    }

    #[test]
    #[expect(
        clippy::disallowed_types,
        reason = "old library fixtures need names the current types reject; JSON key order does not matter"
    )]
    fn a_stored_tag_with_a_truly_blank_name_is_still_refused() {
        let json = serde_json::json!({
            "id": Uuid::new_v4(),
            "name": " \t\n ",
            "color": "teal",
        });
        assert!(serde_json::from_value::<ConnectionTag>(json).is_err());
    }

    #[test]
    #[expect(
        clippy::disallowed_types,
        reason = "old library fixtures need names the current types reject; JSON key order does not matter"
    )]
    fn long_invisible_tag_names_recover_by_id_and_round_trip() {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        for (id, name) in [
            (first, "\u{200b}".repeat(32)),
            (second, format!("{}\u{feff}", "\u{200b}".repeat(31))),
        ] {
            let tag: ConnectionTag = serde_json::from_value(serde_json::json!({
                "id": id,
                "name": name,
                "color": "teal",
            }))
            .expect("an older tag");
            assert_eq!(tag.id, id);
            assert_eq!(tag.name.as_str(), id.simple().to_string());
            let written = serde_json::to_value(&tag).expect("serialize");
            assert_eq!(written["id"], id.to_string());
            assert_eq!(written["name"], id.simple().to_string());
            assert_eq!(written["color"], "teal");
            assert_eq!(serde_json::from_value::<ConnectionTag>(written).expect("reread"), tag);
        }
    }

    #[test]
    #[expect(
        clippy::disallowed_types,
        reason = "old library fixtures need names the current types reject; JSON key order does not matter"
    )]
    fn a_recovered_tag_id_does_not_take_a_visible_name_or_exceed_the_limit() {
        #[derive(Deserialize)]
        struct List {
            #[serde(deserialize_with = "deserialize_list")]
            tags: Vec<ConnectionTag>,
        }

        let id = Uuid::new_v4();
        let plain = id.simple().to_string();
        let second = format!("{} (2)", &plain[..28]);
        let third = format!("{} (3)", &plain[..28]);
        for reverse in [false, true] {
            let mut tags = vec![
                serde_json::json!({"id": id, "name": "\u{200b}".repeat(32), "color": "red"}),
                serde_json::json!({"id": Uuid::new_v4(), "name": plain, "color": "blue"}),
                serde_json::json!({"id": Uuid::new_v4(), "name": second, "color": "teal"}),
            ];
            if reverse {
                tags.reverse();
            }
            let list: List = serde_json::from_value(serde_json::json!({"tags": tags})).expect("recover");
            let recovered = list.tags.iter().find(|tag| tag.id == id).expect("tag kept");
            assert_eq!(recovered.name.as_str(), third);
            assert_eq!(recovered.name.as_str().chars().count(), ConnectionTagName::MAX_CHARS);
            assert!(list.tags.iter().any(|tag| tag.name.as_str() == plain));
            assert!(list.tags.iter().any(|tag| tag.name.as_str() == second));
        }
    }
}
