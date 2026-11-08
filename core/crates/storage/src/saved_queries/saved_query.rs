use std::time::SystemTime;

use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQuery {
    pub id: i64,
    pub name: String,
    pub query: String,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub keyword: Option<String>,
    pub folder_id: Option<i64>,
    pub order: i64,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

impl SavedQuery {
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
            keyword: None,
            folder_id: None,
            order: 0,
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
