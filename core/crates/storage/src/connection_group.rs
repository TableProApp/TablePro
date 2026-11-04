use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Deserializer, Serialize};
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

pub(crate) fn deserialize_list<'de, D>(deserializer: D) -> Result<Vec<ConnectionGroup>, D::Error>
where
    D: Deserializer<'de>,
{
    let stored = Vec::<StoredGroup>::deserialize(deserializer)?;
    let mut recovered = Vec::new();
    let mut held: HashMap<Option<Uuid>, HashSet<String>> = HashMap::new();
    let mut groups = Vec::with_capacity(stored.len());
    for (index, raw) in stored.into_iter().enumerate() {
        let recover = crate::name_rules::shown(&raw.name).is_empty();
        let group = ConnectionGroup::try_from(raw).map_err(serde::de::Error::custom)?;
        if recover {
            recovered.push(index);
        } else {
            held.entry(group.parent_id)
                .or_default()
                .insert(group.name.as_str().to_lowercase());
        }
        groups.push(group);
    }
    // A recovered sibling must not match a visible group during import.
    recovered.sort_unstable_by_key(|&index| groups[index].id);
    for index in recovered {
        let group = &mut groups[index];
        let name =
            crate::name_rules::claim_recovered(group.name.as_str(), None, held.entry(group.parent_id).or_default());
        group.name = ConnectionGroupName::new(&name).map_err(serde::de::Error::custom)?;
    }
    Ok(groups)
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

    /// For a name from a list written before groups had ids. The id comes
    /// from the name, so every read or import of such a list agrees.
    pub fn legacy(name: ConnectionGroupName) -> Self {
        Self {
            id: legacy_id(&name),
            ..Self::new(name, None)
        }
    }
}

// FNV-1a over 128 bits rather than std's hasher, whose output may change
// between Rust releases.
fn legacy_id(name: &ConnectionGroupName) -> Uuid {
    const OFFSET: u128 = 0x6c62_272e_07bb_0142_62b8_2175_6295_c58d;
    const PRIME: u128 = 0x0000_0000_0100_0000_0000_0000_0000_013b;
    let hash = b"tablepro.connection-group\0"
        .iter()
        .chain(name.as_str().as_bytes())
        .fold(OFFSET, |hash, byte| (hash ^ u128::from(*byte)).wrapping_mul(PRIME));
    uuid::Builder::from_custom_bytes(hash.to_be_bytes()).into_uuid()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(value: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(value).expect("a group name")
    }

    #[test]
    fn a_legacy_group_has_the_same_id_for_the_same_name_only() {
        let work = ConnectionGroup::legacy(name("Work"));

        assert_eq!(work.id, ConnectionGroup::legacy(name("Work")).id);
        assert_ne!(work.id, ConnectionGroup::legacy(name("work")).id);
        assert_ne!(work.id, ConnectionGroup::legacy(name("Home")).id);
        assert_eq!(work.parent_id, None);
        // Pinned: a list read before and after an upgrade of the app must
        // give its groups the same ids.
        assert_eq!(work.id.to_string(), "98833b56-6ab5-8600-b70c-fe45a4241f0f");
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
