use std::collections::BTreeMap;

/// A single node in a parsed EXPLAIN query plan tree.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QueryPlanNode {
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
    pub properties: BTreeMap<String, String>,
    pub children: Vec<QueryPlanNode>,
    /// This node's share of the plan's total work (0.0-1.0), filled by
    /// [`QueryPlan::compute_cost_fractions`]. None when the plan reports no cost
    /// anywhere, which is not the same as a share of zero.
    pub cost_fraction: Option<f64>,
    pub warnings: Vec<String>,
    /// The total actual rows over every execution, kept because the per-execution
    /// value the engine prints is rounded.
    pub reported_total_actual_rows: Option<i64>,
    pub missing_indexes: Vec<QueryPlanMissingIndex>,
}

impl QueryPlanNode {
    /// Cost of this node alone, with its children's total cost taken out.
    pub fn exclusive_cost(&self) -> f64 {
        let child_cost: f64 = self
            .children
            .iter()
            .map(|child| child.estimated_total_cost.unwrap_or(0.0))
            .sum();
        (self.estimated_total_cost.unwrap_or(0.0) - child_cost).max(0.0)
    }

    /// `startup..total` when the plan reports both, `total` alone when it reports
    /// only the total, None when it reports no cost.
    pub fn cost_range_text(&self, fraction_digits: usize) -> Option<String> {
        let total = self.estimated_total_cost?;
        match self.estimated_startup_cost {
            Some(startup) => Some(format!(
                "{startup:.digits$}..{total:.digits$}",
                digits = fraction_digits
            )),
            None => Some(format!("{total:.digits$}", digits = fraction_digits)),
        }
    }
}

/// An index the engine's plan says would help, and the statement to create it.
#[derive(Debug, Clone, PartialEq)]
pub struct QueryPlanMissingIndex {
    pub impact: Option<f64>,
    pub create_statement: String,
}

/// A parsed EXPLAIN query plan.
#[derive(Debug, Clone, PartialEq)]
pub struct QueryPlan {
    pub root: QueryPlanNode,
    pub planning_time: Option<f64>,
    pub execution_time: Option<f64>,
    pub raw_text: String,
}

impl QueryPlan {
    /// Set each node's share of the plan's total work.
    ///
    /// The denominator is the sum of every node's exclusive cost, not the root's
    /// total. The root total is not an upper bound on the work below it: PostgreSQL
    /// prices a `Limit` far below its child, so dividing by the root total yielded
    /// shares above 1. Exclusive costs sum to the real total, so the share is bounded
    /// and adds up to 1.
    ///
    /// A plan that reports no cost anywhere leaves every fraction None, so "nothing
    /// was reported" stays distinct from "this node is free".
    pub fn compute_cost_fractions(&mut self) {
        let total = Self::total_exclusive_cost(&self.root);
        if total <= 0.0 {
            return;
        }
        Self::assign_fractions(&mut self.root, total);
    }

    fn total_exclusive_cost(node: &QueryPlanNode) -> f64 {
        node.children.iter().fold(node.exclusive_cost(), |acc, child| {
            acc + Self::total_exclusive_cost(child)
        })
    }

    fn assign_fractions(node: &mut QueryPlanNode, total: f64) {
        node.cost_fraction = Some(node.exclusive_cost() / total);
        for child in &mut node.children {
            Self::assign_fractions(child, total);
        }
    }

    /// Whether any node in the plan satisfies a predicate.
    pub fn contains(&self, predicate: &impl Fn(&QueryPlanNode) -> bool) -> bool {
        Self::node_contains(&self.root, predicate)
    }

    fn node_contains(node: &QueryPlanNode, predicate: &impl Fn(&QueryPlanNode) -> bool) -> bool {
        predicate(node) || node.children.iter().any(|child| Self::node_contains(child, predicate))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(cost: f64, children: Vec<QueryPlanNode>) -> QueryPlanNode {
        QueryPlanNode {
            operation: "Node".into(),
            estimated_total_cost: Some(cost),
            children,
            ..Default::default()
        }
    }

    #[test]
    fn exclusive_cost_subtracts_children() {
        let parent = node(100.0, vec![node(30.0, vec![]), node(20.0, vec![])]);
        assert_eq!(parent.exclusive_cost(), 50.0);
    }

    #[test]
    fn exclusive_cost_never_negative() {
        // A Limit priced below its child would drive the subtraction negative.
        let limit = node(1.0, vec![node(500.0, vec![])]);
        assert_eq!(limit.exclusive_cost(), 0.0);
    }

    #[test]
    fn cost_fractions_are_bounded_and_sum_to_one() {
        let mut plan = QueryPlan {
            root: node(1.0, vec![node(500.0, vec![node(200.0, vec![])])]),
            planning_time: None,
            execution_time: None,
            raw_text: String::new(),
        };
        plan.compute_cost_fractions();
        let mut sum = 0.0;
        let mut stack = vec![&plan.root];
        while let Some(current) = stack.pop() {
            let fraction = current.cost_fraction.expect("fraction set");
            assert!((0.0..=1.0).contains(&fraction), "fraction {fraction} out of range");
            sum += fraction;
            stack.extend(current.children.iter());
        }
        assert!((sum - 1.0).abs() < 1e-9, "fractions sum to {sum}");
    }

    #[test]
    fn no_cost_leaves_fractions_none() {
        let mut plan = QueryPlan {
            root: QueryPlanNode {
                operation: "Node".into(),
                ..Default::default()
            },
            planning_time: None,
            execution_time: None,
            raw_text: String::new(),
        };
        plan.compute_cost_fractions();
        assert_eq!(plan.root.cost_fraction, None);
    }

    #[test]
    fn cost_range_text_shows_startup_and_total() {
        let mut only_total = node(12.0, vec![]);
        assert_eq!(only_total.cost_range_text(2).as_deref(), Some("12.00"));
        only_total.estimated_startup_cost = Some(4.0);
        assert_eq!(only_total.cost_range_text(2).as_deref(), Some("4.00..12.00"));
    }

    #[test]
    fn contains_walks_the_tree() {
        let plan = QueryPlan {
            root: node(
                10.0,
                vec![QueryPlanNode {
                    operation: "Seq Scan".into(),
                    ..Default::default()
                }],
            ),
            planning_time: None,
            execution_time: None,
            raw_text: String::new(),
        };
        assert!(plan.contains(&|node| node.operation == "Seq Scan"));
        assert!(!plan.contains(&|node| node.operation == "Index Scan"));
    }
}
