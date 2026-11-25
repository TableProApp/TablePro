use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::lenient::Identified;

use crate::{ConnectionColor, ConnectionTagName};

/// A label several connections can share. Connections name it by id, so
/// a rename or a new colour reaches every one of them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionTag {
    pub id: Uuid,
    pub name: ConnectionTagName,
    pub color: ConnectionColor,
    // One of the tags macOS starts every library with, which its UI never deletes.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_preset: bool,
}

impl ConnectionTag {
    pub fn new(name: ConnectionTagName, color: ConnectionColor) -> Self {
        Self {
            id: Uuid::new_v4(),
            name,
            color,
            is_preset: false,
        }
    }
}

impl Identified for ConnectionTag {
    fn id(&self) -> Uuid {
        self.id
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
    fn a_stored_tag_keeps_its_name_as_written_and_says_whether_it_is_a_preset() {
        let json = r#"{"id":"550e8400-e29b-41d4-a716-446655440000","name":" \t\n ","color":"teal","is_preset":true}"#;

        let tag = serde_json::from_str::<ConnectionTag>(json).expect("a tag");

        assert_eq!(tag.name.as_str(), " \t\n ");
        assert!(tag.is_preset);
        assert_eq!(serde_json::to_value(&tag).expect("json")["is_preset"], true);
    }
}
