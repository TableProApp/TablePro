use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::lenient::Identified;

use crate::{ConnectionColor, ConnectionGroupName, LibraryIcon};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "StoredGroup")]
pub struct ConnectionGroup {
    pub id: Uuid,
    pub name: ConnectionGroupName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<Uuid>,
    // Among the siblings; a move numbers them from 0 again.
    #[serde(default)]
    pub order: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<ConnectionColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<LibraryIcon>,
    /// Only a top-level group's counts; its subtree and their connections follow it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Uuid>,
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
    icon: Option<LibraryIcon>,
    #[serde(default)]
    project_id: Option<Uuid>,
}

impl From<StoredGroup> for ConnectionGroup {
    fn from(stored: StoredGroup) -> Self {
        Self {
            id: stored.id,
            name: ConnectionGroupName::from_stored(&stored.name),
            parent_id: stored.parent_id,
            order: stored.order,
            color: stored.color,
            icon: stored.icon,
            project_id: stored.project_id,
        }
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
            project_id: None,
        }
    }
}

impl Identified for ConnectionGroup {
    fn id(&self) -> Uuid {
        self.id
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
    fn a_stored_name_is_kept_as_written_blank_included() {
        let stored = |name: &str| format!(r#"{{"id":"{}","name":"{name}"}}"#, Uuid::new_v4());
        let kept: ConnectionGroup = serde_json::from_str(&stored(r" Work\tHome ")).expect("a name");
        let blank: ConnectionGroup = serde_json::from_str(&stored(" ")).expect("a blank name");

        assert_eq!(kept.name.as_str(), " Work\tHome ");
        assert_eq!(blank.name.as_str(), " ");
    }
}
