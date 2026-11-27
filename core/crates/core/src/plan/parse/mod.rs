//! Parsers that turn an engine's EXPLAIN output into a [`QueryPlan`]. One per
//! [`ExplainPlanFormat`]; the driver's variant names the format.

mod json;
mod mysql;
mod postgres;
mod sqlite;
mod tree;

use super::{ExplainPlanFormat, QueryPlan};

/// Parse an engine's EXPLAIN output into a [`QueryPlan`]. None when the format has
/// no structured parser or the text does not parse as that format (the app shows
/// the raw text instead).
pub fn parse(format: ExplainPlanFormat, raw_text: &str) -> Option<QueryPlan> {
    if format == ExplainPlanFormat::POSTGRES_JSON {
        postgres::parse(raw_text)
    } else if format == ExplainPlanFormat::MYSQL_COMPOSITE {
        mysql::parse(raw_text)
    } else if format == ExplainPlanFormat::SQLITE_QUERY_PLAN {
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
        assert!(parse(ExplainPlanFormat::PLAIN_TEXT, "anything").is_none());
    }

    #[test]
    fn the_format_picks_the_parser() {
        assert!(parse(ExplainPlanFormat::SQLITE_QUERY_PLAN, "2\t0\t0\tSCAN TABLE t").is_some());
    }
}
