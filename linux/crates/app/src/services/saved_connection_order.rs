//! The order every connection picker shows the saved connections in.

use std::cmp::Ordering;
use std::collections::HashMap;

use tablepro_storage::{ConnectionGroup, ConnectionTag, GroupTree, SavedConnection};
use uuid::Uuid;

/// A group as the pickers name it: its path, such as `Work / Staging`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct GroupLabels {
    by_id: HashMap<Uuid, String>,
    /// In the order of the library's tree, so a label two groups share
    /// names the first of them.
    listed: Vec<(Uuid, String)>,
}

impl GroupLabels {
    pub(crate) fn new(groups: &[ConnectionGroup]) -> Self {
        let tree = GroupTree::new(groups);
        let listed: Vec<(Uuid, String)> = tree
            .walk()
            .into_iter()
            .filter_map(|group| Some((group.id, tree.label(group.id)?)))
            .collect();
        Self {
            by_id: listed.iter().cloned().collect(),
            listed,
        }
    }

    pub(crate) fn of(&self, connection: &SavedConnection) -> Option<&str> {
        connection
            .group_id
            .and_then(|id| self.by_id.get(&id))
            .map(String::as_str)
    }

    pub(crate) fn group_labelled(&self, label: &str) -> Option<Uuid> {
        self.listed
            .iter()
            .find(|(_, listed)| listed == label)
            .map(|(id, _)| *id)
    }
}

/// Sort the list the way every picker shows it.
///
/// Ungrouped connections lead, because that is where every connection
/// starts and a user with no groups sees the list they always saw.
/// Groups follow in alphabetical order. Inside each block the order is
/// recency-first with an alphabetical tiebreaker, so the connection
/// opened last is the one nearest the top. Never-opened connections
/// fall to the end of their block and sort by name among themselves.
pub(crate) fn sort(connections: &mut [SavedConnection], labels: &GroupLabels) {
    connections.sort_by(|a, b| {
        group_key(labels, a)
            .cmp(&group_key(labels, b))
            .then_with(|| recency_key(a).cmp(&recency_key(b)))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}

/// The order of the window's connection tree: the picker's blocks, each
/// by name rather than by recency, so a connect never moves an open
/// connection's row away from under the pointer.
pub(crate) fn by_name(labels: &GroupLabels, a: &SavedConnection, b: &SavedConnection) -> Ordering {
    group_key(labels, a)
        .cmp(&group_key(labels, b))
        .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        .then_with(|| a.name.cmp(&b.name))
        .then_with(|| a.id.cmp(&b.id))
}

/// Ungrouped sorts before every group, and groups sort by label
/// regardless of how they were capitalised. Two labels that differ only
/// in case stay two blocks, in a fixed order.
fn group_key<'a>(labels: &'a GroupLabels, connection: &SavedConnection) -> Option<(String, &'a str)> {
    labels.of(connection).map(|label| (label.to_lowercase(), label))
}

/// Newest first, with never-opened last. The timestamp is negated
/// rather than compared backwards so it composes with the keys around
/// it.
fn recency_key(connection: &SavedConnection) -> (bool, i64) {
    match connection.last_opened_at {
        Some(at) => (false, -at.timestamp_millis()),
        None => (true, 0),
    }
}

/// Tags read by name, in any case, wherever the list shows them.
pub(crate) fn sort_tags(tags: &mut [ConnectionTag]) {
    tags.sort_by(|a, b| {
        a.name
            .as_str()
            .to_lowercase()
            .cmp(&b.name.as_str().to_lowercase())
            .then_with(|| a.name.cmp(&b.name))
    });
}

/// Every group in `sorted`, once each, in the order the list shows them:
/// the order of the picker's sections and of every Move to Group menu.
pub(crate) fn groups(sorted: &[SavedConnection], labels: &GroupLabels) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for label in sorted.iter().filter_map(|connection| labels.of(connection)) {
        if !found.iter().any(|held| held == label) {
            found.push(label.to_owned());
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    fn connection(name: &str, group: Option<&str>, opened_days_ago: Option<i64>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            query_timeout_secs: None,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: opened_days_ago.map(|days| {
                Utc.timestamp_opt(1_700_000_000 - days * 86_400, 0)
                    .single()
                    .expect("a time")
            }),
            color: None,
            group_id: group.map(crate::test_support::group_id),
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn names(connections: &[SavedConnection]) -> Vec<String> {
        connections.iter().map(|saved| saved.name.clone()).collect()
    }

    fn labels(connections: &[SavedConnection]) -> GroupLabels {
        GroupLabels::new(&crate::test_support::groups_of(connections))
    }

    fn sorted(list: &mut [SavedConnection]) {
        let labels = labels(list);
        sort(list, &labels);
    }

    fn group_list(list: &[SavedConnection]) -> Vec<String> {
        groups(list, &labels(list))
    }

    #[test]
    fn ungrouped_connections_lead_the_list() {
        let mut list = vec![
            connection("in a group", Some("Work"), Some(1)),
            connection("on its own", None, Some(1)),
        ];

        sorted(&mut list);

        assert_eq!(names(&list), vec!["on its own", "in a group"]);
    }

    #[test]
    fn groups_follow_in_alphabetical_order_whatever_the_case() {
        let mut list = vec![
            connection("c", Some("work"), Some(1)),
            connection("a", Some("Archive"), Some(1)),
            connection("b", Some("Personal"), Some(1)),
        ];

        sorted(&mut list);

        assert_eq!(names(&list), vec!["a", "b", "c"]);
    }

    #[test]
    fn the_connection_opened_last_leads_its_own_group() {
        let mut list = vec![
            connection("older", Some("Work"), Some(9)),
            connection("newer", Some("Work"), Some(1)),
            connection("never", Some("Work"), None),
        ];

        sorted(&mut list);

        assert_eq!(names(&list), vec!["newer", "older", "never"]);
    }

    #[test]
    fn never_opened_connections_sort_by_name_among_themselves() {
        let mut list = vec![connection("zeta", None, None), connection("Alpha", None, None)];

        sorted(&mut list);

        assert_eq!(names(&list), vec!["Alpha", "zeta"]);
    }

    #[test]
    fn the_group_list_holds_each_name_once_in_list_order() {
        let mut list = vec![
            connection("a", Some("Work"), Some(1)),
            connection("b", Some("Archive"), Some(1)),
            connection("c", Some("Work"), Some(2)),
            connection("d", None, Some(1)),
        ];
        sorted(&mut list);

        assert_eq!(group_list(&list), ["Archive", "Work"]);
    }

    #[test]
    fn the_name_order_keeps_the_blocks_and_ignores_recency() {
        let mut list = vec![
            connection("zeta", None, Some(1)),
            connection("Beta", Some("work"), Some(1)),
            connection("alpha", Some("Work"), Some(9)),
            connection("Alpha", None, None),
            connection("gamma", Some("Archive"), Some(2)),
        ];

        let labels = labels(&list);
        list.sort_by(|a, b| by_name(&labels, a, b));

        assert_eq!(names(&list), vec!["Alpha", "zeta", "gamma", "alpha", "Beta"]);
        assert_eq!(
            group_list(&list),
            ["Archive", "Work", "work"],
            "the same groups as the picker's"
        );
    }

    #[test]
    fn groups_that_differ_only_in_case_keep_blocks_of_their_own() {
        let mut list = vec![
            connection("a", Some("work"), Some(1)),
            connection("b", Some("Work"), Some(3)),
            connection("c", Some("work"), Some(5)),
            connection("d", Some("Work"), Some(2)),
        ];

        sorted(&mut list);

        assert_eq!(names(&list), vec!["d", "b", "a", "c"]);
        assert_eq!(group_list(&list), ["Work", "work"]);
    }

    #[test]
    fn a_nested_group_sorts_by_its_path_after_its_parent() {
        let name = |name: &str| tablepro_storage::ConnectionGroupName::new(name).expect("a group name");
        let work = ConnectionGroup::new(name("Work"), None);
        let staging = ConnectionGroup::new(name("Staging"), Some(work.id));
        let workshop = ConnectionGroup::new(name("Workshop"), None);
        let labels = GroupLabels::new(&[workshop.clone(), staging.clone(), work.clone()]);
        let filed = |connection: &str, group: &ConnectionGroup| SavedConnection {
            group_id: Some(group.id),
            ..connection_named(connection)
        };
        let mut list = vec![
            filed("in workshop", &workshop),
            filed("in staging", &staging),
            filed("in work", &work),
        ];

        sort(&mut list, &labels);

        assert_eq!(names(&list), vec!["in work", "in staging", "in workshop"]);
        assert_eq!(groups(&list, &labels), ["Work", "Work / Staging", "Workshop"]);
        assert_eq!(labels.group_labelled("Work / Staging"), Some(staging.id));
        assert_eq!(labels.group_labelled("Staging"), None);
    }

    fn connection_named(name: &str) -> SavedConnection {
        connection(name, None, Some(1))
    }
}
