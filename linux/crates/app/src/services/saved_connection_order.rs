//! The order every connection picker shows the saved connections in.

use tablepro_storage::{ConnectionGroupName, SavedConnection};

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
/// regardless of how they were capitalised.
fn group_key(connection: &SavedConnection) -> (bool, String) {
    match &connection.group {
        Some(group) => (true, group.as_str().to_lowercase()),
        None => (false, String::new()),
    }
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

/// Every group in `sorted`, in the order the list shows them, once each.
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
            read_only: false,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: opened_days_ago.map(|days| {
                Utc.timestamp_opt(1_700_000_000 - days * 86_400, 0)
                    .single()
                    .expect("a time")
            }),
            color: None,
            group: group.map(|group| ConnectionGroupName::new(group).expect("a group name")),
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
}
