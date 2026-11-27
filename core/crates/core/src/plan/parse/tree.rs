use crate::plan::QueryPlanNode;

/// Build a forest from a pre-order list where each element carries its own depth.
/// An element is a child of the closest preceding element with a smaller depth.
pub(super) fn forest<E>(
    elements: &[E],
    depth: impl Fn(&E) -> i64,
    make_node: impl Fn(&E, Vec<QueryPlanNode>) -> QueryPlanNode,
) -> Vec<QueryPlanNode> {
    let mut index = 0;
    build(elements, &mut index, -1, &depth, &make_node)
}

fn build<E>(
    elements: &[E],
    index: &mut usize,
    parent_depth: i64,
    depth: &impl Fn(&E) -> i64,
    make_node: &impl Fn(&E, Vec<QueryPlanNode>) -> QueryPlanNode,
) -> Vec<QueryPlanNode> {
    let mut nodes = Vec::new();
    while let Some(element) = elements.get(*index) {
        let element_depth = depth(element);
        if element_depth <= parent_depth {
            break;
        }
        *index += 1;
        let children = build(elements, index, element_depth, depth, make_node);
        nodes.push(make_node(element, children));
    }
    nodes
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forest_nests_by_depth() {
        let elements = [(0, "a"), (1, "b"), (2, "c"), (1, "d"), (0, "e")];
        let roots = forest(
            &elements,
            |&(depth, _)| depth,
            |&(_, name), children| QueryPlanNode {
                operation: name.to_string(),
                children,
                ..Default::default()
            },
        );
        assert_eq!(roots.len(), 2);
        assert_eq!(roots[0].operation, "a");
        assert_eq!(roots[0].children.len(), 2);
        assert_eq!(roots[0].children[0].operation, "b");
        assert_eq!(roots[0].children[0].children[0].operation, "c");
        assert_eq!(roots[0].children[1].operation, "d");
        assert_eq!(roots[1].operation, "e");
    }
}
