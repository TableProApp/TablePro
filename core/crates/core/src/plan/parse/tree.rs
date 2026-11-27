use crate::plan::QueryPlanNode;

/// The single root, or a synthetic node wrapping several roots whose cost is the
/// sum of the roots that report one, so cost fractions stay relative to a real total.
pub(super) fn root(mut roots: Vec<QueryPlanNode>) -> Option<QueryPlanNode> {
    match roots.len() {
        0 => None,
        1 => roots.pop(),
        _ => {
            let costs: Vec<f64> = roots.iter().filter_map(|node| node.estimated_total_cost).collect();
            Some(QueryPlanNode {
                operation: "Query Plan".to_string(),
                estimated_total_cost: (!costs.is_empty()).then(|| costs.iter().sum()),
                children: roots,
                ..Default::default()
            })
        }
    }
}
