use std::time::SystemTime;

use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedQuery {
    pub id: Uuid,
    pub name: String,
    pub query: String,
    // None puts the query in every connection.
    pub connection_id: Option<Uuid>,
    pub connection_name: String,
    pub keyword: Option<String>,
    // A folder this store may not hold yet, which reads as the top level.
    pub folder_id: Option<Uuid>,
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
            id: Uuid::nil(),
            name: "daily".to_owned(),
            query: query.to_owned(),
            connection_id: None,
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
