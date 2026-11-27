use std::collections::BTreeMap;

use serde_json::Value;

use super::json::{Object, loose_f64, object};
use crate::plan::{QueryPlan, QueryPlanNode};

/// MySQL and MariaDB EXPLAIN. A plan over this many bytes is left to the raw view.
const MAX_INPUT_BYTES: usize = 2_000_000;

pub(super) fn parse(raw_text: &str) -> Option<QueryPlan> {
    if raw_text.len() > MAX_INPUT_BYTES {
        return None;
    }
    parse_json(raw_text)
}

/// Parse `EXPLAIN FORMAT=JSON`. Handles MySQL's flat shape and MariaDB's nested one
/// (query_block then filesort, temporary_table, nested_loop).
fn parse_json(raw_text: &str) -> Option<QueryPlan> {
    let trimmed = raw_text.trim();
    if !trimmed.starts_with('{') {
        return None;
    }
    let root: Object = serde_json::from_str(trimmed).ok()?;
    let query_block = object(root.get("query_block")?)?;
    let cost = block_cost(&query_block);

    let mut plan = QueryPlan {
        root: parse_block(&query_block, "Query Block".to_string(), cost),
        planning_time: None,
        execution_time: None,
        raw_text: raw_text.to_string(),
    };
    plan.compute_cost_fractions();
    Some(plan)
}

fn block_cost(block: &Object) -> Option<f64> {
    if let Some(cost) = block.get("cost").and_then(Value::as_f64) {
        return Some(cost);
    }
    let cost_info = object(block.get("cost_info")?)?;
    loose_f64(cost_info.get("query_cost")?)
}

fn parse_block(dict: &Object, operation: String, cost: Option<f64>) -> QueryPlanNode {
    let mut children: Vec<QueryPlanNode> = Vec::new();

    if let Some(table) = dict.get("table").and_then(object) {
        children.push(parse_table(&table));
    }

    if let Some(nested) = dict.get("nested_loop").and_then(Value::as_array) {
        for item in nested {
            if let Some(table) = object(item).and_then(|entry| entry.get("table").and_then(object)) {
                children.push(parse_table(&table));
            }
        }
    }

    // MariaDB: filesort wraps the inner plan.
    if let Some(filesort) = dict.get("filesort").and_then(object) {
        let sort_key = filesort.get("sort_key").and_then(Value::as_str);
        let sort_op = sort_key.map_or_else(|| "Sort".to_string(), |key| format!("Sort ({key})"));
        let inner = parse_block(&filesort, sort_op, None);
        if !inner.children.is_empty() {
            children = vec![inner];
        }
    }

    // MariaDB: temporary_table wraps nested_loop.
    if let Some(temp_table) = dict.get("temporary_table").and_then(object) {
        let inner = parse_block(&temp_table, "Temporary Table".to_string(), None);
        if !inner.children.is_empty() {
            children = inner.children;
        }
    }

    if let Some(ordering) = dict.get("ordering_operation").and_then(object) {
        children.push(parse_block(&ordering, "Sort".to_string(), None));
    }

    if let Some(grouping) = dict.get("grouping_operation").and_then(object) {
        children.push(parse_block(&grouping, "Group".to_string(), None));
    }

    QueryPlanNode {
        operation,
        estimated_total_cost: cost,
        children,
        ..Default::default()
    }
}

/// MariaDB reports one `cost` per table, and those sum to the block's own `cost`.
/// MySQL splits the same quantity into `read_cost` (fetching rows) and `eval_cost`
/// (testing the conditions); `read_cost` alone left each table short by its
/// `eval_cost`, which the wrapper node then absorbed as exclusive cost.
fn table_cost(table: &Object) -> Option<f64> {
    if let Some(mariadb_cost) = table.get("cost").and_then(Value::as_f64) {
        return Some(mariadb_cost);
    }
    let cost_info = object(table.get("cost_info")?)?;
    let read_cost = loose_f64(cost_info.get("read_cost")?)?;
    let eval_cost = cost_info.get("eval_cost").and_then(loose_f64).unwrap_or(0.0);
    Some(read_cost + eval_cost)
}

fn parse_table(table: &Object) -> QueryPlanNode {
    let rows = table
        .get("rows")
        .and_then(Value::as_i64)
        .or_else(|| table.get("rows_examined_per_scan").and_then(Value::as_i64))
        .or_else(|| table.get("rows_produced_per_join").and_then(Value::as_i64));

    let mut properties = BTreeMap::new();
    if let Some(key) = table.get("key").and_then(Value::as_str) {
        properties.insert("Key".to_string(), key.to_string());
    }
    if let Some(refs) = table.get("ref").and_then(Value::as_array) {
        let joined: Vec<&str> = refs.iter().filter_map(Value::as_str).collect();
        if !joined.is_empty() {
            properties.insert("Ref".to_string(), joined.join(", "));
        }
    }
    if let Some(condition) = table.get("attached_condition").and_then(Value::as_str) {
        properties.insert("Filter".to_string(), condition.to_string());
    }
    if let Some(filtered) = table.get("filtered").and_then(loose_f64)
        && filtered < 100.0
    {
        properties.insert("Filtered".to_string(), format!("{filtered:.0}%"));
    }

    QueryPlanNode {
        operation: table
            .get("access_type")
            .and_then(Value::as_str)
            .unwrap_or("ALL")
            .to_string(),
        relation: table.get("table_name").and_then(Value::as_str).map(str::to_string),
        estimated_total_cost: table_cost(table),
        estimated_rows: rows,
        properties,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mysql_nested_loop_with_split_costs() {
        let raw = r#"{
          "query_block": {
            "select_id": 1,
            "cost_info": { "query_cost": "2.40" },
            "nested_loop": [
              {
                "table": {
                  "table_name": "orders",
                  "access_type": "ALL",
                  "rows_examined_per_scan": 100,
                  "cost_info": { "read_cost": "1.00", "eval_cost": "0.50" }
                }
              },
              {
                "table": {
                  "table_name": "items",
                  "access_type": "ref",
                  "key": "fk_order",
                  "rows_examined_per_scan": 3,
                  "filtered": "50.00",
                  "cost_info": { "read_cost": "0.80", "eval_cost": "0.10" }
                }
              }
            ]
          }
        }"#;
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.operation, "Query Block");
        assert_eq!(plan.root.estimated_total_cost, Some(2.40));
        assert_eq!(plan.root.children.len(), 2);

        let orders = &plan.root.children[0];
        assert_eq!(orders.relation.as_deref(), Some("orders"));
        // read_cost + eval_cost.
        assert_eq!(orders.estimated_total_cost, Some(1.50));
        assert_eq!(orders.estimated_rows, Some(100));

        let items = &plan.root.children[1];
        assert_eq!(items.operation, "ref");
        assert_eq!(items.properties.get("Key").map(String::as_str), Some("fk_order"));
        assert_eq!(items.properties.get("Filtered").map(String::as_str), Some("50%"));
    }

    #[test]
    fn mariadb_filesort_wraps_the_inner_plan() {
        let raw = r#"{
          "query_block": {
            "filesort": {
              "sort_key": "t.id",
              "table": { "table_name": "t", "access_type": "ALL", "cost": 0.9 }
            }
          }
        }"#;
        let plan = parse(raw).expect("parses");
        let sort = &plan.root.children[0];
        assert_eq!(sort.operation, "Sort (t.id)");
        assert_eq!(sort.children[0].relation.as_deref(), Some("t"));
        assert_eq!(sort.children[0].estimated_total_cost, Some(0.9));
    }

    #[test]
    fn non_json_is_none() {
        assert!(parse("id\tselect_type\ttable\n1\tSIMPLE\tt").is_none());
    }
}
