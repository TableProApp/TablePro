use std::collections::HashMap;

use tablepro_core::plan::{self, ExplainStep, ExplainVariant, QueryPlan, QueryPlanMissingIndex, QueryPlanNode};

/// A parsed EXPLAIN query plan, for the plan view.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueryPlanInfo {
    pub root: QueryPlanNodeInfo,
    pub planning_time: Option<f64>,
    pub execution_time: Option<f64>,
    pub raw_text: String,
}

/// One node of the plan tree. `children` makes it recursive.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueryPlanNodeInfo {
    pub operation: String,
    pub relation: Option<String>,
    pub schema: Option<String>,
    pub alias: Option<String>,
    pub estimated_startup_cost: Option<f64>,
    pub estimated_total_cost: Option<f64>,
    pub estimated_rows: Option<i64>,
    pub estimated_width: Option<i64>,
    pub actual_startup_time: Option<f64>,
    pub actual_total_time: Option<f64>,
    pub actual_rows: Option<i64>,
    pub actual_loops: Option<i64>,
    /// This node's share of the plan's total work (0.0-1.0), None when no cost was reported.
    pub cost_fraction: Option<f64>,
    pub properties: HashMap<String, String>,
    pub warnings: Vec<String>,
    pub reported_total_actual_rows: Option<i64>,
    pub missing_indexes: Vec<QueryPlanMissingIndexInfo>,
    pub children: Vec<QueryPlanNodeInfo>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueryPlanMissingIndexInfo {
    pub impact: Option<f64>,
    pub create_statement: String,
}

/// One EXPLAIN option an engine offers, for the plan menu.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExplainVariantInfo {
    pub id: String,
    pub label: String,
    pub sql_prefix: String,
    pub format: String,
    /// The app prepends `sql_prefix` and runs the statement for a prefix variant.
    /// A driver variant needs engine support the Windows app does not have yet.
    pub is_sql_prefix: bool,
    /// Running the variant executes the user's statement, so the app gates it.
    pub runs_statement: bool,
}

impl From<QueryPlan> for QueryPlanInfo {
    fn from(plan: QueryPlan) -> Self {
        Self {
            root: plan.root.into(),
            planning_time: plan.planning_time,
            execution_time: plan.execution_time,
            raw_text: plan.raw_text,
        }
    }
}

impl From<QueryPlanNode> for QueryPlanNodeInfo {
    fn from(node: QueryPlanNode) -> Self {
        Self {
            operation: node.operation,
            relation: node.relation,
            schema: node.schema,
            alias: node.alias,
            estimated_startup_cost: node.estimated_startup_cost,
            estimated_total_cost: node.estimated_total_cost,
            estimated_rows: node.estimated_rows,
            estimated_width: node.estimated_width,
            actual_startup_time: node.actual_startup_time,
            actual_total_time: node.actual_total_time,
            actual_rows: node.actual_rows,
            actual_loops: node.actual_loops,
            cost_fraction: node.cost_fraction,
            properties: node.properties.into_iter().collect(),
            warnings: node.warnings,
            reported_total_actual_rows: node.reported_total_actual_rows,
            missing_indexes: node
                .missing_indexes
                .into_iter()
                .map(QueryPlanMissingIndexInfo::from)
                .collect(),
            children: node.children.into_iter().map(QueryPlanNodeInfo::from).collect(),
        }
    }
}

impl From<QueryPlanMissingIndex> for QueryPlanMissingIndexInfo {
    fn from(index: QueryPlanMissingIndex) -> Self {
        Self {
            impact: index.impact,
            create_statement: index.create_statement,
        }
    }
}

impl From<&ExplainVariant> for ExplainVariantInfo {
    fn from(variant: &ExplainVariant) -> Self {
        Self {
            id: variant.id.to_string(),
            label: variant.label.to_string(),
            sql_prefix: variant.sql_prefix.to_string(),
            format: variant.format.as_str().to_string(),
            is_sql_prefix: matches!(variant.step, ExplainStep::SqlPrefix),
            runs_statement: variant.runs_statement(),
        }
    }
}

/// The EXPLAIN options the engine offers, in menu order. Empty for an unknown
/// engine or one without query-plan support.
#[uniffi::export]
pub fn explain_variants(engine: String) -> Vec<ExplainVariantInfo> {
    crate::drivers::registry()
        .get(&engine)
        .map(|driver| driver.explain_variants().iter().map(ExplainVariantInfo::from).collect())
        .unwrap_or_default()
}

/// Parse an engine's EXPLAIN output into a plan tree, keyed by the variant's
/// format. None when the format has no parser or the text does not parse (the app
/// shows the raw text instead).
#[uniffi::export]
pub fn parse_query_plan(format: String, raw_text: String) -> Option<QueryPlanInfo> {
    plan::parse(&format, &raw_text).map(QueryPlanInfo::from)
}

#[cfg(all(test, feature = "engines"))]
mod tests {
    use super::*;

    #[test]
    fn postgres_lists_its_two_variants() {
        let variants = explain_variants("postgres".to_string());
        let ids: Vec<&str> = variants.iter().map(|variant| variant.id.as_str()).collect();
        assert_eq!(ids, ["explain", "analyze"]);
        assert_eq!(variants[0].format, "postgresJson");
        assert!(variants[0].is_sql_prefix);
        assert!(!variants[0].runs_statement);
        assert!(variants[1].runs_statement);
    }

    #[test]
    fn an_unknown_engine_has_no_variants() {
        assert!(explain_variants("nosuch".to_string()).is_empty());
    }

    #[test]
    fn parse_builds_a_tree_for_a_known_format() {
        let plan = parse_query_plan("sqliteQueryPlan".to_string(), "2\t0\t0\tSCAN TABLE t".to_string());
        assert_eq!(plan.map(|plan| plan.root.operation), Some("SCAN TABLE t".to_string()));
    }

    #[test]
    fn parse_returns_none_for_an_unknown_format() {
        assert!(parse_query_plan("plainText".to_string(), "anything".to_string()).is_none());
    }
}
