use std::sync::Arc;

/// SQL the user wrote, carried as it was typed.
///
/// It is shared rather than copied because the same text goes to the
/// driver, the history and the results list, and an editor buffer can
/// be megabytes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UserSql(Arc<str>);

impl UserSql {
    pub fn new(sql: impl Into<Arc<str>>) -> Self {
        Self(sql.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.trim().is_empty()
    }
}

impl std::fmt::Display for UserSql {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitespace_only_sql_counts_as_empty() {
        assert!(UserSql::new("   \n\t").is_empty());
        assert!(!UserSql::new("SELECT 1").is_empty());
    }
}
