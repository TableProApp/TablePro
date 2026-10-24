//! The order every connection picker shows the saved connections in.

use tablepro_storage::{ConnectionGroupName, ConnectionTag, SavedConnection};

/// Sort the list the way every picker shows it.
///
/// Ungrouped connections lead, because that is where every connection
/// starts and a user with no groups sees the list they always saw.
/// Groups follow in alphabetical order. Inside each block the order is
/// recency-first with an alphabetical tiebreaker, so the connection
/// opened last is the one nearest the top. Never-opened connections
/// fall to the end of their block and sort by name among themselves.
pub(crate) fn sort(connections: &mut [SavedConnection]) {
    connections.sort_by(|a, b| {
        group_key(a)
            .cmp(&group_key(b))
            .then_with(|| recency_key(a).cmp(&recency_key(b)))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}

/// Ungrouped sorts before every group, and groups sort by name
/// regardless of how they were capitalised. Two names that differ only
/// in case stay two blocks, in a fixed order.
fn group_key(connection: &SavedConnection) -> Option<(String, &str)> {
    connection
        .group
        .as_ref()
        .map(|group| (group.as_str().to_lowercase(), group.as_str()))
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
pub(crate) fn groups(sorted: &[SavedConnection]) -> Vec<ConnectionGroupName> {
    let mut found: Vec<ConnectionGroupName> = Vec::new();
    for group in sorted.iter().filter_map(|connection| connection.group.as_ref()) {
        if !found.contains(group) {
            found.push(group.clone());
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
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: opened_days_ago.map(|days| {
                Utc.timestamp_opt(1_700_000_000 - days * 86_400, 0)
                    .single()
                    .expect("a time")
            }),
            color: None,
            group: group.map(|group| ConnectionGroupName::new(group).expect("a group name")),
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn names(connections: &[SavedConnection]) -> Vec<String> {
        connections.iter().map(|saved| saved.name.clone()).collect()
    }

    #[test]
    fn ungrouped_connections_lead_the_list() {
        let mut list = vec![
            connection("in a group", Some("Work"), Some(1)),
            connection("on its own", None, Some(1)),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["on its own", "in a group"]);
    }

    #[test]
    fn groups_follow_in_alphabetical_order_whatever_the_case() {
        let mut list = vec![
            connection("c", Some("work"), Some(1)),
            connection("a", Some("Archive"), Some(1)),
            connection("b", Some("Personal"), Some(1)),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["a", "b", "c"]);
    }

    #[test]
    fn the_connection_opened_last_leads_its_own_group() {
        let mut list = vec![
            connection("older", Some("Work"), Some(9)),
            connection("newer", Some("Work"), Some(1)),
            connection("never", Some("Work"), None),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["newer", "older", "never"]);
    }

    #[test]
    fn never_opened_connections_sort_by_name_among_themselves() {
        let mut list = vec![connection("zeta", None, None), connection("Alpha", None, None)];

        sort(&mut list);

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
        sort(&mut list);

        let names: Vec<String> = groups(&list).into_iter().map(String::from).collect();
        assert_eq!(names, ["Archive", "Work"]);
    }

    #[test]
    fn groups_that_differ_only_in_case_keep_blocks_of_their_own() {
        let mut list = vec![
            connection("a", Some("work"), Some(1)),
            connection("b", Some("Work"), Some(3)),
            connection("c", Some("work"), Some(5)),
            connection("d", Some("Work"), Some(2)),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["d", "b", "a", "c"]);
        let groups: Vec<String> = groups(&list).into_iter().map(String::from).collect();
        assert_eq!(groups, ["Work", "work"]);
    }
}
