use std::collections::HashMap;

use tablepro_storage::{ConnectionGroup, ConnectionTag, GroupTree, SavedConnection};
use uuid::Uuid;

// A group's path, such as `Work / Staging`, for search and display only:
// two groups can share one.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct GroupLabels {
    by_id: HashMap<Uuid, String>,
}

impl GroupLabels {
    pub(crate) fn new(groups: &[ConnectionGroup]) -> Self {
        let tree = GroupTree::new(groups);
        let by_id = tree
            .walk()
            .into_iter()
            .filter_map(|group| Some((group.id, tree.label(group.id)?)))
            .collect();
        Self { by_id }
    }

    pub(crate) fn of(&self, connection: &SavedConnection) -> Option<&str> {
        connection
            .group_id
            .and_then(|id| self.by_id.get(&id))
            .map(String::as_str)
    }
}

pub(crate) fn sort_tags(tags: &mut [ConnectionTag]) {
    tags.sort_by(|a, b| {
        a.name
            .as_str()
            .to_lowercase()
            .cmp(&b.name.as_str().to_lowercase())
            .then_with(|| a.name.cmp(&b.name))
    });
}

#[cfg(test)]
mod tests {
    use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionTagName};

    use super::*;

    fn group(name: &str, parent: Option<&ConnectionGroup>) -> ConnectionGroup {
        ConnectionGroup::new(
            ConnectionGroupName::new(name).expect("a group name"),
            parent.map(|parent| parent.id),
        )
    }

    #[test]
    fn a_group_reads_by_its_path_and_two_groups_with_one_path_keep_their_ids() {
        let work = group("Work", None);
        let staging = group("Staging", Some(&work));
        let flat = group("Work / Staging", None);
        let labels = GroupLabels::new(&[work.clone(), staging.clone(), flat.clone()]);
        let filed = |group: &ConnectionGroup| SavedConnection {
            group_id: Some(group.id),
            ..crate::test_support::saved_connection("x")
        };

        assert_eq!(labels.of(&filed(&work)), Some("Work"));
        assert_eq!(labels.of(&filed(&staging)), Some("Work / Staging"));
        assert_eq!(labels.of(&filed(&flat)), Some("Work / Staging"));
        assert_eq!(labels.of(&crate::test_support::saved_connection("y")), None);
    }

    #[test]
    fn tags_read_by_name_in_any_case() {
        let tag =
            |name: &str| ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), ConnectionColor::Red);
        let mut tags = vec![tag("zeta"), tag("Acme"), tag("acme"), tag("Beta")];

        sort_tags(&mut tags);

        let names: Vec<&str> = tags.iter().map(|tag| tag.name.as_str()).collect();
        assert_eq!(names, ["Acme", "acme", "Beta", "zeta"]);
    }
}
