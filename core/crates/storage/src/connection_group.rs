use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ConnectionColor, ConnectionGroupName, GroupIcon};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "StoredGroup")]
pub struct ConnectionGroup {
    pub id: Uuid,
    pub name: ConnectionGroupName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<Uuid>,
    /// Every write numbers each parent's groups from 0 again.
    #[serde(default)]
    pub order: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<ConnectionColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<GroupIcon>,
}

#[derive(Deserialize)]
struct StoredGroup {
    id: Uuid,
    name: String,
    #[serde(default)]
    parent_id: Option<Uuid>,
    #[serde(default)]
    order: u32,
    #[serde(default)]
    color: Option<ConnectionColor>,
    #[serde(default)]
    icon: Option<GroupIcon>,
}

impl TryFrom<StoredGroup> for ConnectionGroup {
    type Error = crate::GroupNameError;

    fn try_from(stored: StoredGroup) -> Result<Self, Self::Error> {
        Ok(Self {
            id: stored.id,
            name: ConnectionGroupName::from_stored(&stored.name).ok_or(crate::GroupNameError::Empty)?,
            parent_id: stored.parent_id,
            order: stored.order,
            color: stored.color,
            icon: stored.icon,
        })
    }
}

impl ConnectionGroup {
    /// The macOS limit, so a tree made on either fits both.
    pub const MAX_DEPTH: usize = 3;

    pub fn new(name: ConnectionGroupName, parent_id: Option<Uuid>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name,
            parent_id,
            order: 0,
            color: None,
            icon: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(value: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(value).expect("a group name")
    }

    #[test]
    fn a_group_is_stored_without_the_fields_it_leaves_empty() {
        let group = ConnectionGroup::new(name("Work"), None);

        let json = serde_json::to_string(&group).expect("serialize");

        assert_eq!(json, format!(r#"{{"id":"{}","name":"Work","order":0}}"#, group.id));
        assert_eq!(
            serde_json::from_str::<ConnectionGroup>(&json).expect("deserialize"),
            group
        );
    }

    #[test]
    fn a_stored_name_is_cleaned_and_a_blank_one_refused() {
        let stored = |name: &str| format!(r#"{{"id":"{}","name":"{name}"}}"#, Uuid::new_v4());
        let cleaned: ConnectionGroup = serde_json::from_str(&stored(r" Work\tHome ")).expect("a cleaned name");

        assert_eq!(cleaned.name.as_str(), "Work Home");
        assert!(serde_json::from_str::<ConnectionGroup>(&stored(" ")).is_err());
    }
}
