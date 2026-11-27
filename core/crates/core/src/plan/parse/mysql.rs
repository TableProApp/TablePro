use std::collections::BTreeMap;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use super::json::{Object, loose_f64, object};
use super::tree;
use crate::plan::{QueryPlan, QueryPlanNode};

/// MySQL and MariaDB EXPLAIN. A plan over this many bytes is left to the raw view.
const MAX_INPUT_BYTES: usize = 2_000_000;

pub(super) fn parse(raw_text: &str) -> Option<QueryPlan> {
    if raw_text.len() > MAX_INPUT_BYTES {
        return None;
    }
    parse_json(raw_text).or_else(|| parse_tree(raw_text))
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

/// Parse MySQL's `EXPLAIN FORMAT=TREE` (and the tree `EXPLAIN ANALYZE` prints). A
/// node starts at each `->` line; its metrics group and any wrapped lines belong to
/// it. Depth comes from the `->` indent, children from the forest helper.
fn parse_tree(raw_text: &str) -> Option<QueryPlan> {
    let raw_nodes = parse_raw_nodes(raw_text)?;
    if raw_nodes.is_empty() {
        return None;
    }
    let roots = tree::forest(&raw_nodes, |node| node.depth as i64, make_node);
    let execution_time = roots
        .iter()
        .filter_map(total_execution_time)
        .fold(None::<f64>, |max, time| Some(max.map_or(time, |max| max.max(time))));
    let root = tree::root(roots)?;
    let mut plan = QueryPlan {
        root,
        planning_time: None,
        execution_time,
        raw_text: raw_text.to_string(),
    };
    plan.compute_cost_fractions();
    Some(plan)
}

const MAX_NODES: usize = 10_000;
const MAX_DEPTH: usize = 128;
const NUMBER: &str = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?";

static ACTUAL_METRICS_RE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(&format!(
        r"\s+\(actual time=({NUMBER})\.\.({NUMBER})\s+rows=({NUMBER})\s+loops=({NUMBER})\)\s*$"
    ))
    .ok()
});
static COST_METRICS_RE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(&format!(r"\s+\(cost=({NUMBER})\s+rows=({NUMBER})\)\s*$")).ok());
static NEVER_EXECUTED_RE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?i)\s+\(never executed\)\s*$").ok());

struct RawNode {
    depth: usize,
    text: String,
}

#[derive(Default)]
struct ParsedMetrics {
    estimated_cost: Option<f64>,
    estimated_rows: Option<i64>,
    actual_startup_time: Option<f64>,
    actual_total_time: Option<f64>,
    actual_rows: Option<i64>,
    actual_loops: Option<i64>,
    was_executed: bool,
}

fn make_node(raw: &RawNode, children: Vec<QueryPlanNode>) -> QueryPlanNode {
    let (operation, relation, properties, metrics) = parse_node_text(&raw.text);
    QueryPlanNode {
        operation,
        relation,
        estimated_total_cost: metrics.estimated_cost,
        estimated_rows: metrics.estimated_rows,
        actual_startup_time: metrics.actual_startup_time,
        actual_total_time: metrics.actual_total_time,
        actual_rows: metrics.actual_rows,
        actual_loops: metrics.actual_loops,
        properties,
        children,
        ..Default::default()
    }
}

/// A node starts at every `->` line, so a line in between belongs to the node above
/// it. None when a node or depth limit is passed, leaving the plan to the raw view.
fn parse_raw_nodes(raw_text: &str) -> Option<Vec<RawNode>> {
    let mut nodes: Vec<RawNode> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut pending: Option<(usize, String)> = None;

    for line in raw_text.lines() {
        if let Some(node_line) = node_line(line) {
            if !flush_pending(&mut pending, &mut stack, &mut nodes) {
                return None;
            }
            pending = Some(node_line);
            continue;
        }
        let continuation = line.trim();
        if let Some((_, text)) = pending.as_mut()
            && !continuation.is_empty()
        {
            text.push(' ');
            text.push_str(continuation);
        }
    }

    if !flush_pending(&mut pending, &mut stack, &mut nodes) {
        return None;
    }
    Some(nodes)
}

/// Close the pending node into `nodes` at the depth its indent sets. False when a
/// limit is reached.
fn flush_pending(pending: &mut Option<(usize, String)>, stack: &mut Vec<usize>, nodes: &mut Vec<RawNode>) -> bool {
    let Some((indent, text)) = pending.take() else {
        return true;
    };
    while stack.last().is_some_and(|&last| indent <= last) {
        stack.pop();
    }
    if stack.len() >= MAX_DEPTH || nodes.len() >= MAX_NODES {
        return false;
    }
    stack.push(indent);
    nodes.push(RawNode {
        depth: stack.len() - 1,
        text,
    });
    true
}

/// The indent (tab = 4) and text of a `-> ...` line, None for any other line.
fn node_line(line: &str) -> Option<(usize, String)> {
    let leading_end = line.find(|c| c != ' ' && c != '\t').unwrap_or(line.len());
    let leading = &line[..leading_end];
    let text = line[leading_end..].strip_prefix("->")?.trim();
    if text.is_empty() {
        return None;
    }
    let indent = leading.chars().map(|c| if c == '\t' { 4 } else { 1 }).sum();
    Some((indent, text.to_string()))
}

fn parse_node_text(raw_text: &str) -> (String, Option<String>, BTreeMap<String, String>, ParsedMetrics) {
    let mut text = raw_text.trim().to_string();
    let mut metrics = ParsedMetrics {
        was_executed: true,
        ..Default::default()
    };

    if let Some(captures) = ACTUAL_METRICS_RE.as_ref().and_then(|re| re.captures(&text)) {
        metrics.actual_startup_time = nonnegative_f64(captures.get(1));
        metrics.actual_total_time = nonnegative_f64(captures.get(2));
        metrics.actual_rows = rounded_i64(captures.get(3));
        metrics.actual_loops = whole_i64(captures.get(4));
        text = truncate_at_match(&text, &captures);
    } else if let Some(found) = NEVER_EXECUTED_RE.as_ref().and_then(|re| re.find(&text)) {
        metrics.was_executed = false;
        text = text[..found.start()].trim().to_string();
    }

    if let Some(captures) = COST_METRICS_RE.as_ref().and_then(|re| re.captures(&text)) {
        metrics.estimated_cost = nonnegative_f64(captures.get(1));
        metrics.estimated_rows = rounded_i64(captures.get(2));
        text = truncate_at_match(&text, &captures);
    }

    let (operation, relation, mut properties) = access_presentation(&text);
    if !metrics.was_executed {
        properties.insert("Execution".to_string(), "Never executed".to_string());
    }
    (operation, relation, properties, metrics)
}

fn truncate_at_match(text: &str, captures: &regex::Captures) -> String {
    match captures.get(0) {
        Some(whole) => text[..whole.start()].trim().to_string(),
        None => text.to_string(),
    }
}

/// An access node reads as `<op> on <relation> [using <index>]`, so a scan, lookup
/// or search splits into an operation and a relation; anything else stays as written.
fn access_presentation(text: &str) -> (String, Option<String>, BTreeMap<String, String>) {
    let Some(on_pos) = find_ascii_ci(text, " on ") else {
        return (text.to_string(), None, BTreeMap::new());
    };
    if !is_access_operation(&text[..on_pos]) {
        return (text.to_string(), None, BTreeMap::new());
    }
    let operation = text[..on_pos].trim().to_string();
    let remainder = text[on_pos + " on ".len()..].trim();
    let Some(relation) = leading_identifier(remainder) else {
        return (text.to_string(), None, BTreeMap::new());
    };

    let mut properties = BTreeMap::new();
    properties.insert("Details".to_string(), text.to_string());
    let suffix = &remainder[relation.len()..];
    if let Some(using_pos) = find_ascii_ci(suffix, "using ")
        && let Some(index_name) = leading_identifier(&suffix[using_pos + "using ".len()..])
    {
        properties.insert("Index Name".to_string(), index_name);
    }
    (operation, Some(relation), properties)
}

fn is_access_operation(operation: &str) -> bool {
    let lower = operation.to_lowercase();
    lower.contains("scan") || lower.contains("lookup") || lower.contains("search")
}

/// A backtick- or angle-quoted name closes with its pair; a bare name runs to the
/// first space or `(`. The quotes are kept, as MySQL prints them.
fn leading_identifier(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let first = trimmed.chars().next()?;
    let closing = match first {
        '`' => Some('`'),
        '<' => Some('>'),
        _ => None,
    };
    if let Some(closing) = closing {
        let rest = &trimmed[first.len_utf8()..];
        if let Some(pos) = rest.find(closing) {
            let end = first.len_utf8() + pos + closing.len_utf8();
            return Some(trimmed[..end].to_string());
        }
    }
    let identifier: String = trimmed
        .chars()
        .take_while(|&c| !c.is_whitespace() && c != '(')
        .collect();
    (!identifier.is_empty()).then_some(identifier)
}

/// Byte offset of an ASCII needle in a haystack, case-insensitive. The needle is
/// ASCII, so a match lands on a char boundary and its offset indexes `haystack`.
fn find_ascii_ci(haystack: &str, needle: &str) -> Option<usize> {
    let (hay, need) = (haystack.as_bytes(), needle.as_bytes());
    if need.is_empty() || hay.len() < need.len() {
        return None;
    }
    (0..=hay.len() - need.len()).find(|&start| hay[start..start + need.len()].eq_ignore_ascii_case(need))
}

fn nonnegative_f64(capture: Option<regex::Match>) -> Option<f64> {
    let value: f64 = capture?.as_str().parse().ok()?;
    (value.is_finite() && value >= 0.0).then_some(value)
}

fn rounded_i64(capture: Option<regex::Match>) -> Option<i64> {
    let value = nonnegative_f64(capture)?;
    (value < i64::MAX as f64).then(|| value.round() as i64)
}

fn whole_i64(capture: Option<regex::Match>) -> Option<i64> {
    let value = nonnegative_f64(capture)?;
    (value.round() == value && value < i64::MAX as f64).then_some(value as i64)
}

/// Wall time of one top-level root: per-loop time times loops, kept finite.
fn total_execution_time(node: &QueryPlanNode) -> Option<f64> {
    let time = node.actual_total_time?;
    let total = time * node.actual_loops.unwrap_or(1) as f64;
    total.is_finite().then_some(total)
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
    fn non_json_falls_through_to_the_tree_parser() {
        // A tabular EXPLAIN has no `->` lines, so neither parser claims it.
        assert!(parse("id\tselect_type\ttable\n1\tSIMPLE\tt").is_none());
    }

    #[test]
    fn parses_a_tree_with_cost_and_actual_metrics() {
        let raw = "\
-> Nested loop inner join  (cost=1.40 rows=2) (actual time=0.05..0.12 rows=2 loops=1)
    -> Table scan on orders  (cost=0.40 rows=4) (actual time=0.02..0.03 rows=4 loops=1)
    -> Index lookup on items using fk_order (cost=0.60 rows=1) (actual time=0.01..0.02 rows=1 loops=4)";
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.operation, "Nested loop inner join");
        assert_eq!(plan.root.estimated_total_cost, Some(1.40));
        assert_eq!(plan.root.estimated_rows, Some(2));
        assert_eq!(plan.root.actual_total_time, Some(0.12));
        assert_eq!(plan.root.children.len(), 2);
        // loops=1, so the top node's wall time is its per-loop time.
        assert_eq!(plan.execution_time, Some(0.12));

        let scan = &plan.root.children[0];
        assert_eq!(scan.operation, "Table scan");
        assert_eq!(scan.relation.as_deref(), Some("orders"));

        let lookup = &plan.root.children[1];
        assert_eq!(lookup.operation, "Index lookup");
        assert_eq!(lookup.relation.as_deref(), Some("items"));
        assert_eq!(
            lookup.properties.get("Index Name").map(String::as_str),
            Some("fk_order")
        );
        assert_eq!(lookup.actual_loops, Some(4));
    }

    #[test]
    fn a_never_executed_node_is_marked_and_keeps_no_metrics() {
        let raw = "-> Index lookup on t using k (cost=0.35 rows=1) (never executed)";
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.operation, "Index lookup");
        assert_eq!(plan.root.estimated_total_cost, Some(0.35));
        assert_eq!(plan.root.actual_total_time, None);
        assert_eq!(
            plan.root.properties.get("Execution").map(String::as_str),
            Some("Never executed")
        );
    }

    #[test]
    fn a_quoted_relation_keeps_its_backticks() {
        let raw = "-> Table scan on `my orders`  (cost=1.00 rows=10)";
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.relation.as_deref(), Some("`my orders`"));
    }

    #[test]
    fn a_continuation_line_joins_its_node() {
        let raw = "\
-> Filter: (t.a = 1
    and t.b = 2)  (cost=2.00 rows=5)
    -> Table scan on t  (cost=1.00 rows=100)";
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.operation, "Filter: (t.a = 1 and t.b = 2)");
        assert_eq!(plan.root.estimated_total_cost, Some(2.00));
        assert_eq!(plan.root.children.len(), 1);
    }

    #[test]
    fn json_is_preferred_over_the_tree_parser() {
        let raw = r#"{ "query_block": { "table": { "table_name": "t", "access_type": "ALL" } } }"#;
        let plan = parse(raw).expect("parses");
        assert_eq!(plan.root.operation, "Query Block");
    }
}
