//! Parsers that turn an engine's EXPLAIN output into a [`QueryPlan`]. One per
//! [`ExplainPlanFormat`]; the driver's variant names the format.

mod json;
mod mysql;
mod postgres;
mod sqlite;
mod tree;

use super::{ExplainPlanFormat, QueryPlan};

/// Parse an engine's EXPLAIN output into a [`QueryPlan`], keyed by the variant's
/// [`ExplainPlanFormat`] string. None when the format has no structured parser or
/// the text does not parse as that format (the app shows the raw text instead).
pub fn parse(format: &str, raw_text: &str) -> Option<QueryPlan> {
    if format == ExplainPlanFormat::POSTGRES_JSON.as_str() {
        postgres::parse(raw_text)
    } else if format == ExplainPlanFormat::MYSQL_COMPOSITE.as_str() {
        mysql::parse(raw_text)
    } else if format == ExplainPlanFormat::SQLITE_QUERY_PLAN.as_str() {
        sqlite::parse(raw_text)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unparsed_format_returns_none() {
        assert!(parse(ExplainPlanFormat::PLAIN_TEXT.as_str(), "anything").is_none());
    }

    #[test]
    fn the_format_picks_the_parser() {
        assert!(parse(ExplainPlanFormat::SQLITE_QUERY_PLAN.as_str(), "2\t0\t0\tSCAN TABLE t").is_some());
    }
}
