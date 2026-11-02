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

    pub fn sql(&self) -> &str {
        &self.sql
    }

    pub fn params(&self) -> &[BoundParam] {
        &self.params
    }

    pub fn into_parts(self) -> (String, Vec<BoundParam>) {
        (self.sql, self.params)
    }

    /// This statement inside SQL the app wrote around it, such as
    /// `EXPLAIN`. The parameters keep their markers and their order, so
    /// `before` and `after` must not hold a marker of their own: that is
    /// the one way to wrap a statement without letting the two drift
    /// apart, which a public `new` would allow.
    pub fn wrapped(self, before: &str, after: &str) -> Self {
        Self {
            sql: format!("{before}{}{after}", self.sql),
            params: self.params,
        }
    }
}
