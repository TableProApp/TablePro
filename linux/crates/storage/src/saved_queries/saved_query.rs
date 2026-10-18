use std::time::SystemTime;

use uuid::Uuid;

/// One query the user named and kept.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQuery {
    pub id: i64,
    pub name: String,
    pub query: String,
    /// The connection it was saved against. A saved query is written
    /// for one database's schema, so it is listed under that
    /// connection rather than offered everywhere.
    pub connection_id: Uuid,
    /// The connection's name as of the last save, which is what the
    /// list shows when the connection itself is gone.
    pub connection_name: String,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

impl SavedQuery {
    /// The first non-empty line, for a list row's subtitle.
    pub fn summary(&self) -> &str {
        self.query
            .lines()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .unwrap_or("")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn saved(query: &str) -> SavedQuery {
        SavedQuery {
            id: 1,
            name: "daily".to_owned(),
            query: query.to_owned(),
            connection_id: Uuid::nil(),
            connection_name: "local".to_owned(),
            created_at: SystemTime::UNIX_EPOCH,
            updated_at: SystemTime::UNIX_EPOCH,
        }
    }

    #[test]
    fn the_summary_skips_leading_blank_lines() {
        assert_eq!(saved("\n\n  SELECT 1\nFROM t").summary(), "SELECT 1");
    }

    #[test]
    fn an_empty_query_summarises_to_nothing() {
        assert_eq!(saved("   \n\n").summary(), "");
    }
}
