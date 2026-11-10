use std::collections::HashSet;
use std::sync::Arc;

use tablepro_storage::saved_queries::SavedQuery;
use uuid::Uuid;

// One lowercase entry per field, so a search never matches across two fields.
pub(super) type SearchSnapshot = Arc<[(i64, String)]>;

pub(super) struct Listing {
    pub(super) queries: Vec<(u32, SavedQuery)>,
    pub(super) snapshot: SearchSnapshot,
}

impl Listing {
    pub(super) fn new(queries: Vec<SavedQuery>, active: Option<Uuid>) -> Self {
        let snapshot = snapshot(&queries);
        Self {
            queries: grouped(queries, active),
            snapshot,
        }
    }
}

// Each query with its group's rank. A group is a connection id, so two
// connections sharing a name stay apart; the active one comes first.
fn grouped(queries: Vec<SavedQuery>, active: Option<Uuid>) -> Vec<(u32, SavedQuery)> {
    let mut groups: Vec<(Uuid, Vec<SavedQuery>)> = Vec::new();
    for saved in queries {
        match groups
            .iter_mut()
            .find(|(connection, _)| *connection == saved.connection_id)
        {
            Some((_, members)) => members.push(saved),
            None => groups.push((saved.connection_id, vec![saved])),
        }
    }
    if let Some(active) = active {
        // A stable sort, so the other groups keep the store's order.
        groups.sort_by_key(|(connection, _)| *connection != active);
    }
    groups
        .into_iter()
        .zip(0u32..)
        .flat_map(|((_, members), rank)| members.into_iter().map(move |saved| (rank, saved)))
        .collect()
}

fn snapshot(queries: &[SavedQuery]) -> SearchSnapshot {
    queries
        .iter()
        .flat_map(|saved| {
            [&saved.name, &saved.query, &saved.connection_name].map(|field| (saved.id, field.to_lowercase()))
        })
        .collect()
}

// The connection's name counts, so typing it narrows the list to that
// connection without a filter control.
pub(super) fn matches(snapshot: &[(i64, String)], needle: &str) -> HashSet<i64> {
    let needle = needle.trim().to_lowercase();
    snapshot
        .iter()
        .filter(|(_, haystack)| haystack.contains(needle.as_str()))
        .map(|(id, _)| *id)
        .collect()
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;

    fn saved(name: &str, query: &str, connection: &str) -> SavedQuery {
        on_connection(name, query, connection, Uuid::nil())
    }

    fn on_connection(name: &str, query: &str, connection: &str, connection_id: Uuid) -> SavedQuery {
        SavedQuery {
            id: 1,
            name: name.to_owned(),
            query: query.to_owned(),
            connection_id,
            connection_name: connection.to_owned(),
            keyword: None,
            folder_id: None,
            order: 0,
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    // The connection named at the start of each group.
    fn group_names(groups: &[(u32, SavedQuery)]) -> Vec<String> {
        let mut names = Vec::new();
        let mut last = None;
        for (rank, saved) in groups {
            if last != Some(*rank) {
                names.push(saved.connection_name.clone());
                last = Some(*rank);
            }
        }
        names
    }

    fn found(query: &SavedQuery, needle: &str) -> bool {
        matches(&snapshot(std::slice::from_ref(query)), needle).contains(&query.id)
    }

    #[test]
    fn queries_are_grouped_by_the_connection_they_were_saved_against() {
        let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", local),
            on_connection("b", "SELECT 2", "staging", staging),
            on_connection("c", "SELECT 3", "local", local),
        ];

        let groups = grouped(queries, None);

        assert_eq!(group_names(&groups), vec!["local", "staging"]);
        let listed: Vec<(u32, &str)> = groups
            .iter()
            .map(|(rank, saved)| (*rank, saved.name.as_str()))
            .collect();
        assert_eq!(listed, vec![(0_u32, "a"), (0, "c"), (1, "b")]);
    }

    #[test]
    fn the_connection_the_user_is_on_is_listed_first() {
        let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", local),
            on_connection("b", "SELECT 2", "staging", staging),
        ];

        let groups = grouped(queries, Some(staging));

        assert_eq!(group_names(&groups), vec!["staging", "local"]);
    }

    #[test]
    fn two_connections_sharing_a_name_stay_apart() {
        // Duplicating a connection and renaming neither is enough for
        // this: the id is what says they are different.
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
        let queries = vec![
            on_connection("a", "SELECT 1", "local", first),
            on_connection("b", "SELECT 2", "local", second),
        ];

        let groups = grouped(queries, None);

        assert_eq!(group_names(&groups), vec!["local", "local"]);
    }

    #[test]
    fn a_search_that_matches_nothing_finds_no_query() {
        let queries = vec![saved("daily", "SELECT 1", "local")];

        assert!(matches(&snapshot(&queries), "invoices").is_empty());
    }

    #[test]
    fn an_empty_search_matches_everything() {
        assert!(found(&saved("daily", "SELECT 1", "local"), ""));
        assert!(found(&saved("daily", "SELECT 1", "local"), "   "));
    }

    #[test]
    fn a_search_reads_the_name_the_sql_and_the_connection() {
        let query = saved("daily report", "SELECT * FROM orders", "staging");

        assert!(found(&query, "report"));
        assert!(found(&query, "orders"));
        assert!(found(&query, "staging"));
        assert!(!found(&query, "invoices"));
    }

    #[test]
    fn a_search_ignores_case_and_surrounding_space() {
        assert!(found(&saved("Daily", "SELECT 1", "local"), "  daily  "));
        assert!(found(&saved("daily", "SELECT 1", "local"), "DAILY"));
    }

    #[test]
    fn a_search_never_matches_across_two_fields() {
        let query = saved("ab", "cd", "ef");

        assert!(!found(&query, "bc"));
        assert!(!found(&query, "de"));
    }
}
