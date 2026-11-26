// A keyword names one saved query in a connection. Two devices can each give it to a query of their own, and a pull then
// brings a second holder: the query created first keeps it, the lower id breaking a tie, and each other one loses it.
// The store takes a loser without its keyword, so the push sends the release and every device settles on the same
// holder, as the Swift engines' `SavedQueryKeywordResolver` did. A query of no connection never competes: the store
// keeps those unique itself.

use std::collections::BTreeMap;

use serde_json::Value;

// The saved queries that lose their keyword, by the id each is given with.
pub fn losers<'a>(queries: impl IntoIterator<Item = (&'a str, &'a Value)>) -> Vec<&'a str> {
    let mut slots: BTreeMap<(&str, &str), Vec<(i64, String, &str)>> = BTreeMap::new();
    for (id, fields) in queries {
        let text = |member: &str| fields.get(member).and_then(Value::as_str);
        let (Some(keyword), Some(connection)) = (text("keyword"), text("connection_id")) else {
            continue;
        };
        // A query with no creation time never takes a keyword from one that has it.
        let created = fields.get("created_at").and_then(Value::as_i64).unwrap_or(i64::MAX);
        slots
            .entry((connection, keyword))
            .or_default()
            .push((created, id.to_uppercase(), id));
    }
    let mut out: Vec<&str> = slots
        .into_values()
        .flat_map(|mut holders| {
            holders.sort();
            holders.into_iter().skip(1).map(|(_, _, id)| id)
        })
        .collect();
    out.sort_unstable();
    out
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const CONNECTION: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";

    fn query(keyword: Option<&str>, connection: Option<&str>, created: i64) -> Value {
        json!({"name": "q", "query": "SELECT 1", "keyword": keyword, "connection_id": connection, "created_at": created})
    }

    #[test]
    fn nothing_loses_while_no_two_queries_of_a_connection_share_a_keyword() {
        let rev = query(Some("rev"), Some(CONNECTION), 1_000);
        let cost = query(Some("cost"), Some(CONNECTION), 2_000);
        let elsewhere = query(Some("rev"), Some("E6C12C96-3CBD-4A0E-9F41-E36B47F35D84"), 3_000);

        assert!(losers([("a", &rev), ("b", &cost), ("c", &elsewhere)]).is_empty());
    }

    #[test]
    fn queries_of_no_connection_never_compete() {
        let first = query(Some("rev"), None, 1_000);
        let second = query(Some("rev"), None, 2_000);

        assert!(losers([("a", &first), ("b", &second)]).is_empty());
    }

    #[test]
    fn the_query_created_first_keeps_the_keyword() {
        let older = query(Some("rev"), Some(CONNECTION), 1_000);
        let newer = query(Some("rev"), Some(CONNECTION), 2_000);
        let newest = query(Some("rev"), Some(CONNECTION), 3_000);

        assert_eq!(losers([("c", &newest), ("a", &older), ("b", &newer)]), vec!["b", "c"]);
    }

    #[test]
    fn two_created_at_the_same_moment_are_settled_by_id_in_upper_case() {
        let low = "00000000-0000-0000-0000-000000000001";
        let high = "ffffffff-0000-0000-0000-000000000001";
        let same = query(Some("rev"), Some(CONNECTION), 1_000);

        assert_eq!(losers([(high, &same), (low, &same)]), vec![high]);
    }

    #[test]
    fn a_query_with_no_creation_time_loses_to_one_that_has_it() {
        let dated = query(Some("rev"), Some(CONNECTION), 5_000);
        let mut undated = query(Some("rev"), Some(CONNECTION), 0);
        undated.as_object_mut().unwrap().remove("created_at");

        assert_eq!(losers([("a", &undated), ("b", &dated)]), vec!["a"]);
    }

    #[test]
    fn every_device_releases_the_same_loser() {
        let older = query(Some("rev"), Some(CONNECTION), 1_000);
        let newer = query(Some("rev"), Some(CONNECTION), 2_000);

        assert_eq!(
            losers([("a", &older), ("b", &newer)]),
            losers([("b", &newer), ("a", &older)])
        );
    }
}
