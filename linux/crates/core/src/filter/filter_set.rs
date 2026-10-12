use serde::{Deserialize, Serialize};

use super::FilterRule;

/// Every rule on a table's filter strip, joined under one combinator.
///
/// Nested groups are out of scope: a user who needs a boolean tree has
/// the SQL editor.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FilterSet {
    #[serde(default)]
    pub combinator: Combinator,
    #[serde(default)]
    pub rules: Vec<FilterRule>,
    /// A predicate the user wrote as SQL, for what the rule editor does
    /// not model. It is joined with the rules verbatim, so it has to
    /// parse as exactly one expression first: see
    /// `validate_raw_predicate`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_sql: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Combinator {
    #[default]
    And,
    Or,
}

impl FilterSet {
    /// No rules and no SQL, so the query needs no WHERE at all.
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty() && self.raw_predicate().is_none()
    }

    pub fn len(&self) -> usize {
        self.rules.len() + usize::from(self.raw_predicate().is_some())
    }

    /// The user's SQL predicate, or `None` when it is blank.
    pub fn raw_predicate(&self) -> Option<&str> {
        self.extra_sql.as_deref().map(str::trim).filter(|sql| !sql.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_sql_is_no_filter() {
        let set = FilterSet {
            extra_sql: Some("   ".to_owned()),
            ..FilterSet::default()
        };

        assert!(set.is_empty());
        assert_eq!(set.len(), 0);
        assert_eq!(set.raw_predicate(), None);
    }
}
