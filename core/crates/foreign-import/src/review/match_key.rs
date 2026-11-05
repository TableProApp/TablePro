// Two entries name one connection when these match. The core keeps a Redis database index in
// `database` and a socket path in `host`, so the macOS key's extra fields have no home here.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) struct MatchKey {
    host: String,
    port: u16,
    database: String,
    username: String,
}

impl MatchKey {
    pub(super) fn new(host: &str, port: u16, database: &str, username: &str, key_value: bool) -> Self {
        let database = normalized(database);
        // A key-value engine opens database 0 when none is named.
        let database = if key_value && database.is_empty() {
            "0".to_owned()
        } else {
            database
        };
        Self {
            host: normalized(host),
            port,
            database,
            username: normalized(username),
        }
    }
}

fn normalized(value: &str) -> String {
    value.trim().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_database_and_username_match_ignoring_case_and_surrounding_spaces() {
        let local = MatchKey::new("db.example.com", 5432, "app", "admin", false);
        let imported = MatchKey::new(" DB.example.com ", 5432, " App ", " ADMIN ", false);
        assert_eq!(local, imported);
    }

    #[test]
    fn a_different_port_or_username_is_a_different_connection() {
        let base = MatchKey::new("h", 5432, "app", "admin", false);
        assert_ne!(base, MatchKey::new("h", 5433, "app", "admin", false));
        assert_ne!(base, MatchKey::new("h", 5432, "app", "readonly", false));
    }

    #[test]
    fn a_key_value_database_index_distinguishes_and_none_named_is_zero() {
        let zero = MatchKey::new("cache", 6379, "", "", true);
        assert_eq!(zero, MatchKey::new("cache", 6379, " 0 ", "", true));
        assert_ne!(zero, MatchKey::new("cache", 6379, "1", "", true));
        assert_ne!(
            MatchKey::new("h", 1, "", "", false),
            MatchKey::new("h", 1, "0", "", false)
        );
    }
}
