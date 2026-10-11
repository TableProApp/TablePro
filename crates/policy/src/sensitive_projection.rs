use sqlparser::ast::{Expr, Query, SelectItem, SetExpr, Statement, TableFactor};
#[cfg(test)]
use sqlparser::parser::Parser;

#[cfg(test)]
use crate::classify::dialect_for;
use crate::mask::column_is_sensitive;

#[cfg(test)]
pub fn sensitive_projection(sql: &str, driver_id: &str, patterns: &[String], output_columns: usize) -> Vec<bool> {
    let dialect = dialect_for(driver_id);
    let trimmed = sql.trim();
    let Ok(statements) = Parser::parse_sql(dialect.as_ref(), trimmed) else {
        return vec![true; output_columns];
    };
    projection_from_statements(&statements, patterns)
        .filter(|positions| positions.len() == output_columns)
        .unwrap_or_else(|| vec![true; output_columns])
}

pub(crate) fn projection_from_statements(statements: &[Statement], patterns: &[String]) -> Option<Vec<bool>> {
    let [Statement::Query(query)] = statements else {
        return None;
    };
    select_projection_sensitivity(query, patterns)
}

fn select_projection_sensitivity(query: &Query, patterns: &[String]) -> Option<Vec<bool>> {
    if query.with.is_some() {
        return None;
    }
    let SetExpr::Select(select) = query.body.as_ref() else {
        return None;
    };
    if let [item] = select.projection.as_slice()
        && matches!(item, SelectItem::Wildcard(_) | SelectItem::QualifiedWildcard(_, _))
    {
        let [table] = select.from.as_slice() else {
            return None;
        };
        if !table.joins.is_empty() {
            return None;
        }
        let TableFactor::Derived { subquery, .. } = &table.relation else {
            return None;
        };
        return select_projection_sensitivity(subquery, patterns);
    }
    let mut sensitive = Vec::with_capacity(select.projection.len());
    for item in &select.projection {
        match item {
            SelectItem::UnnamedExpr(expr) | SelectItem::ExprWithAlias { expr, .. } => {
                sensitive.push(expr_references_sensitive(expr, patterns));
            }
            SelectItem::Wildcard(_) | SelectItem::QualifiedWildcard(_, _) => return None,
        }
    }
    Some(sensitive)
}

fn expr_references_sensitive(expr: &Expr, patterns: &[String]) -> bool {
    let rendered = expr.to_string();
    let lowered = rendered.to_ascii_lowercase();
    record_serialization_constructor(&lowered)
        || text_identifiers(&rendered).any(|ident| column_is_sensitive(ident, patterns))
}

fn record_serialization_constructor(lowered: &str) -> bool {
    for name in [
        "row_to_json(",
        "to_json(",
        "to_jsonb(",
        "json_agg(",
        "jsonb_agg(",
        "json_object_agg(",
        "jsonb_object_agg(",
        "json_build_object(",
        "jsonb_build_object(",
        "json_object(",
        "jsonb_object(",
    ] {
        if let Some(function_name) = name.strip_suffix('(')
            && contains_function_call(lowered, function_name)
        {
            return true;
        }
    }
    false
}

fn contains_function_call(sql: &str, function_name: &str) -> bool {
    sql.match_indices(function_name).any(|(start, _)| {
        let preceding_boundary = sql[..start]
            .chars()
            .next_back()
            .is_none_or(|character| !character.is_ascii_alphanumeric() && character != '_');
        let after_name = &sql[start + function_name.len()..];
        let after_name = after_name
            .trim_start()
            .strip_prefix('"')
            .unwrap_or(after_name.trim_start());
        preceding_boundary && after_name.trim_start().starts_with('(')
    })
}

fn text_identifiers(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sensitive_patterns() -> Vec<String> {
        crate::mask::DEFAULT_SENSITIVE_PATTERNS
            .iter()
            .map(|p| (*p).to_string())
            .collect()
    }

    #[test]
    fn an_aliased_sensitive_column_is_flagged() {
        let positions = sensitive_projection("SELECT pan AS p FROM cards", "postgres", &sensitive_patterns(), 1);
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_sensitive_column_wrapped_in_an_expression_is_flagged() {
        let positions = sensitive_projection(
            "SELECT substr(pan,1,8) FROM cards",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_wildcard_over_a_derived_table_sees_through_to_the_inner_alias() {
        let positions = sensitive_projection(
            "SELECT * FROM (SELECT pan AS v FROM cards) t",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_wildcard_over_a_derived_join_is_redacted_fail_closed() {
        let positions = sensitive_projection(
            "SELECT * FROM (SELECT amount AS a FROM orders) t JOIN audit_log ON t.a = audit_log.amount",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_sensitive_identifier_with_underscores_keeps_its_full_name() {
        let patterns = vec!["credit_card_number".to_string()];
        let positions = sensitive_projection(
            "SELECT credit_card_number AS safe_label FROM accounts",
            "postgres",
            &patterns,
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn an_unrelated_column_is_not_flagged() {
        let positions = sensitive_projection("SELECT amount AS a FROM orders", "postgres", &sensitive_patterns(), 1);
        assert_eq!(positions, vec![false]);
    }

    #[test]
    fn a_plain_explain_of_a_query_keeps_plan_output_redacted() {
        let positions = sensitive_projection(
            "EXPLAIN SELECT * FROM cards WHERE pan = '4111111111111111'",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn explain_analyze_and_non_query_plans_remain_redacted() {
        for sql in ["EXPLAIN ANALYZE SELECT * FROM cards", "EXPLAIN DELETE FROM cards"] {
            assert_eq!(
                sensitive_projection(sql, "postgres", &sensitive_patterns(), 1),
                vec![true],
                "{sql}"
            );
        }
    }

    #[test]
    fn a_plain_wildcard_over_a_real_table_is_redacted_fail_closed() {
        assert_eq!(
            sensitive_projection("SELECT * FROM cards", "postgres", &sensitive_patterns(), 2),
            vec![true; 2]
        );
    }

    #[test]
    fn a_cte_wildcard_is_redacted_fail_closed() {
        let sql = "WITH d AS (SELECT pan AS p FROM cards) SELECT * FROM d";
        assert_eq!(
            sensitive_projection(sql, "postgres", &sensitive_patterns(), 1),
            vec![true]
        );
    }

    #[test]
    fn a_cte_alias_keeps_sensitive_lineage() {
        let positions = sensitive_projection(
            "WITH d AS (SELECT pan AS p FROM cards) SELECT p FROM d",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_union_masks_the_output_when_any_branch_is_sensitive() {
        let positions = sensitive_projection(
            "SELECT pan AS p FROM cards UNION ALL SELECT label AS p FROM archives",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn row_to_json_of_a_record_is_treated_as_sensitive() {
        let positions = sensitive_projection(
            "SELECT row_to_json(c) FROM cards c",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn a_returning_alias_keeps_sensitive_lineage() {
        let positions = sensitive_projection(
            "INSERT INTO cards (pan) VALUES ('4111111111111111') RETURNING pan AS p",
            "postgres",
            &sensitive_patterns(),
            1,
        );
        assert_eq!(positions, vec![true]);
    }

    #[test]
    fn unrecognized_query_shapes_redact_their_result_values() {
        let patterns = sensitive_patterns();
        for sql in [
            "WITH d AS (SELECT pan AS p FROM cards) SELECT p FROM d",
            "SELECT pan AS p FROM cards UNION ALL SELECT label AS p FROM archives",
            "SELECT row_to_json(c) FROM cards c",
            "INSERT INTO cards (pan) VALUES ('4111111111111111') RETURNING pan AS p",
        ] {
            let positions = sensitive_projection(sql, "postgres", &patterns, 1);
            let result = tablepro_core::QueryResult {
                columns: vec![tablepro_core::ColumnInfo {
                    name: "p".into(),
                    data_type: "text".into(),
                    nullable: true,
                    primary_key: false,
                    is_auto_increment: false,
                    default_value: None,
                    is_generated: false,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
                }],
                rows: vec![vec![tablepro_core::Value::Text("sensitive".into())]],
                truncated: false,
            };
            let masked = crate::mask::apply_masking(result, &patterns, Some(&positions));
            assert_eq!(
                masked.rows[0][0],
                tablepro_core::Value::Text("***REDACTED***".into()),
                "{sql}"
            );
        }
    }

    #[test]
    fn set_operations_and_nested_ctes_fail_closed_for_sensitive_lineage() {
        for sql in [
            "SELECT pan AS p FROM cards INTERSECT SELECT label AS p FROM archives",
            "SELECT pan AS p FROM cards EXCEPT SELECT label AS p FROM archives",
            "WITH outer_q AS (WITH inner_q AS (SELECT pan AS p FROM cards) SELECT p FROM inner_q) SELECT p FROM outer_q",
            "SELECT to_json(c) FROM cards c",
            "SELECT jsonb_build_object('pan', pan) FROM cards",
            "SELECT json_agg(c) FROM cards c",
            "SELECT \"json_agg\"(c) FROM cards c",
            "SELECT jsonb_agg(c) FROM cards c",
            "SELECT json_object_agg('row', c) FROM cards c",
            "SELECT jsonb_object_agg('row', c) FROM cards c",
        ] {
            assert_eq!(
                sensitive_projection(sql, "postgres", &sensitive_patterns(), 1),
                vec![true],
                "{sql}"
            );
        }
    }
}
