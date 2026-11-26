use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ConnectionColor, ConnectionProjectName, GroupIcon};

// All Connections is no project and has no entry (core ADR 0067).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "StoredProject")]
pub struct ConnectionProject {
    pub id: Uuid,
    pub name: ConnectionProjectName,
    /// Every write numbers the projects from 0 again.
    #[serde(default)]
    pub order: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<ConnectionColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<GroupIcon>,
}

#[derive(Deserialize)]
struct StoredProject {
    id: Uuid,
    name: String,
    #[serde(default)]
    order: u32,
    #[serde(default)]
    color: Option<ConnectionColor>,
    #[serde(default)]
    icon: Option<GroupIcon>,
}

impl TryFrom<StoredProject> for ConnectionProject {
    type Error = crate::ProjectNameError;

    fn try_from(stored: StoredProject) -> Result<Self, Self::Error> {
        Ok(Self {
            id: stored.id,
            name: ConnectionProjectName::from_stored(&stored.name)?,
            order: stored.order,
            color: stored.color,
            icon: stored.icon,
        })
    }
}

impl ConnectionProject {
    pub fn new(name: ConnectionProjectName) -> Self {
        Self {
            id: Uuid::new_v4(),
            name,
            order: 0,
            color: None,
            icon: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_is_stored_without_the_fields_it_leaves_empty() {
        let project = ConnectionProject::new(ConnectionProjectName::new("Acme").expect("a name"));

        let json = serde_json::to_string(&project).expect("serialize");

        assert_eq!(json, format!(r#"{{"id":"{}","name":"Acme","order":0}}"#, project.id));
        assert_eq!(
            serde_json::from_str::<ConnectionProject>(&json).expect("deserialize"),
            project
        );
    }

    #[test]
    fn a_stored_name_is_cleaned_and_a_blank_one_refused() {
        let stored = |name: &str| format!(r#"{{"id":"{}","name":"{name}"}}"#, Uuid::new_v4());
        let cleaned: ConnectionProject = serde_json::from_str(&stored(r" Acme\tEU ")).expect("a cleaned name");

        assert_eq!(cleaned.name.as_str(), "Acme EU");
        assert!(serde_json::from_str::<ConnectionProject>(&stored(" ")).is_err());
    }
}
