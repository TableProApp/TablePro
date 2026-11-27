use std::collections::BTreeMap;

use serde_json::Value;

use super::json::{Object, object, str_field, value_to_string};
use crate::plan::{QueryPlan, QueryPlanNode};

/// Keys read into named fields, so they do not repeat in `properties`.
const KNOWN_KEYS: &[&str] = &[
    "Node Type",
    "Relation Name",
    "Schema",
    "Alias",
    "Startup Cost",
    "Total Cost",
    "Plan Rows",
    "Plan Width",
    "Actual Startup Time",
    "Actual Total Time",
    "Actual Rows",
    "Actual Loops",
    "Plans",
];

/// Parse PostgreSQL `EXPLAIN (FORMAT JSON)` and `EXPLAIN (ANALYZE, FORMAT JSON)`.
pub(super) fn parse(raw_text: &str) -> Option<QueryPlan> {
    let roots: Vec<Object> = serde_json::from_str(raw_text).ok()?;
    let root = roots.into_iter().next()?;
    let plan = object(root.get("Plan")?)?;

    let planning_time = root.get("Planning Time").and_then(Value::as_f64);
    let execution_time = root
        .get("Execution Time")
        .or_else(|| root.get("Total Runtime"))
        .and_then(Value::as_f64);

    let mut query_plan = QueryPlan {
        root: parse_node(plan),
        planning_time,
        execution_time,
        raw_text: raw_text.to_string(),
    };
    query_plan.compute_cost_fractions();
    Some(query_plan)
}

fn parse_node(dict: Object) -> QueryPlanNode {
    let children = dict
        .get("Plans")
        .and_then(Value::as_array)
        .map(|plans| plans.iter().filter_map(object).map(parse_node).collect())
        .unwrap_or_default();

    let mut properties = BTreeMap::new();
    for (key, value) in &dict {
        if !KNOWN_KEYS.contains(&key.as_str()) {
            properties.insert(key.clone(), value_to_string(value));
        }
    }

    QueryPlanNode {
        operation: str_field(&dict, "Node Type").unwrap_or_else(|| "Unknown".to_string()),
        relation: str_field(&dict, "Relation Name"),
        schema: str_field(&dict, "Schema"),
        alias: str_field(&dict, "Alias"),
        estimated_startup_cost: dict.get("Startup Cost").and_then(Value::as_f64),
        estimated_total_cost: dict.get("Total Cost").and_then(Value::as_f64),
        estimated_rows: dict.get("Plan Rows").and_then(Value::as_i64),
        estimated_width: dict.get("Plan Width").and_then(Value::as_i64),
        actual_startup_time: dict.get("Actual Startup Time").and_then(Value::as_f64),
        actual_total_time: dict.get("Actual Total Time").and_then(Value::as_f64),
        actual_rows: dict.get("Actual Rows").and_then(Value::as_i64),
        actual_loops: dict.get("Actual Loops").and_then(Value::as_i64),
        properties,
        children,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"[
      {
        "Plan": {
          "Node Type": "Limit",
          "Startup Cost": 0.0,
          "Total Cost": 0.04,
          "Plan Rows": 2,
          "Plan Width": 4,
          "Plans": [
            {
              "Node Type": "Sort",
              "Startup Cost": 10.0,
              "Total Cost": 12.0,
              "Plan Rows": 100,
              "Plan Width": 4,
              "Sort Key": ["id"],
              "Plans": [
                {
                  "Node Type": "Seq Scan",
                  "Relation Name": "t",
                  "Schema": "public",
                  "Startup Cost": 0.0,
                  "Total Cost": 5.0,
                  "Plan Rows": 100,
                  "Plan Width": 4
                }
              ]
            }
          ]
        },
        "Planning Time": 0.1,
        "Execution Time": 0.5
      }
    ]"#;

    #[test]
    fn parses_tree_times_and_leaf_fields() {
        let plan = parse(SAMPLE).expect("parses");
        assert_eq!(plan.planning_time, Some(0.1));
        assert_eq!(plan.execution_time, Some(0.5));
        assert_eq!(plan.root.operation, "Limit");

        let sort = &plan.root.children[0];
        assert_eq!(sort.operation, "Sort");
        // A non-known key becomes a display property.
        assert_eq!(sort.properties.get("Sort Key").map(String::as_str), Some("[\"id\"]"));

        let scan = &sort.children[0];
        assert_eq!(scan.operation, "Seq Scan");
        assert_eq!(scan.relation.as_deref(), Some("t"));
        assert_eq!(scan.schema.as_deref(), Some("public"));
        assert_eq!(scan.estimated_total_cost, Some(5.0));
    }

    #[test]
    fn cost_fractions_stay_bounded_under_a_limit() {
        // The Limit is priced below its child; exclusive-cost fractions keep it <= 1.
        let plan = parse(SAMPLE).expect("parses");
        assert_eq!(plan.root.operation, "Limit");
        let fraction = plan.root.cost_fraction.expect("fraction set");
        assert!((0.0..=1.0).contains(&fraction), "fraction {fraction} out of range");
    }

    #[test]
    fn rejects_non_json() {
        assert!(parse("Seq Scan on t  (cost=0.00..5.00 rows=100 width=4)").is_none());
    }
}
