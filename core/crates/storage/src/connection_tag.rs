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
            name: ConnectionTagName::from_stored(&stored.name)?,
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
    fn a_stored_tag_with_a_blank_name_is_refused() {
        let json = r#"{"id":"550e8400-e29b-41d4-a716-446655440000","name":" \t\n ","color":"teal"}"#;

        assert!(serde_json::from_str::<ConnectionTag>(json).is_err());
    }
}
