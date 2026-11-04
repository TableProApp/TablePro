use serde::{Deserialize, Serialize};
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
    fn a_stored_tag_with_a_truly_blank_name_is_still_refused() {
        let json = serde_json::json!({
            "id": Uuid::new_v4(),
            "name": " \t\n ",
            "color": "teal",
        });
        assert!(serde_json::from_value::<ConnectionTag>(json).is_err());
    }

    #[test]
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
}
