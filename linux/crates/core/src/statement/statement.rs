use super::BoundParam;

/// SQL plus the parameters it takes, built together so they cannot
/// drift apart.
///
/// Nothing here interpolates a value into the text: every value the
/// user supplied is a parameter, which is what keeps a cell edit from
/// becoming an injection.
#[derive(Debug, Clone, PartialEq)]
pub struct Statement {
    sql: String,
    params: Vec<BoundParam>,
}

impl Statement {
    pub(super) fn new(sql: String, params: Vec<BoundParam>) -> Self {
        Self { sql, params }
    }

    /// For a builder that assembled the SQL and the parameters itself,
    /// in the order the placeholders name them.
    pub fn from_parts(sql: String, params: Vec<BoundParam>) -> Self {
        Self { sql, params }
    }

    pub fn sql(&self) -> &str {
        &self.sql
    }

    pub fn params(&self) -> &[BoundParam] {
        &self.params
    }

    pub fn into_parts(self) -> (String, Vec<BoundParam>) {
        (self.sql, self.params)
    }
}
