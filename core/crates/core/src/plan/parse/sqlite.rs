use super::tree;
use crate::plan::{QueryPlan, QueryPlanNode};

/// One `EXPLAIN QUERY PLAN` row: id, parent, (notused), detail.
struct Row {
    id: i64,
    parent: i64,
    detail: String,
}

/// Parse SQLite `EXPLAIN QUERY PLAN` output (tab-separated id/parent/notused/detail
/// rows). A line that is not four tab-separated columns is taken as a detail node.
pub(super) fn parse(raw_text: &str) -> Option<QueryPlan> {
    let mut rows: Vec<Row> = Vec::new();
    for line in raw_text.split('\n').filter(|line| !line.is_empty()) {
        let parts: Vec<&str> = line.split('\t').collect();
        let parsed = (parts.len() >= 4)
            .then(|| {
                let id = parts[0].trim().parse::<i64>().ok()?;
                let parent = parts[1].trim().parse::<i64>().ok()?;
                Some(Row {
                    id,
                    parent,
                    detail: parts[3].trim().to_string(),
                })
            })
            .flatten();
        match parsed {
            Some(row) => rows.push(row),
            None => {
                let id = rows.len() as i64;
                rows.push(Row {
                    id,
                    parent: -1,
                    detail: line.to_string(),
                });
            }
        }
    }
    if rows.is_empty() {
        return None;
    }

    let min_parent = rows.iter().map(|row| row.parent).min().unwrap_or(0);
    let root = tree::root(build_children(&rows, min_parent))?;
    Some(QueryPlan {
        root,
        planning_time: None,
        execution_time: None,
        raw_text: raw_text.to_string(),
    })
}

fn build_children(rows: &[Row], parent_id: i64) -> Vec<QueryPlanNode> {
    rows.iter()
        .filter(|row| row.parent == parent_id)
        .map(|row| QueryPlanNode {
            operation: row.detail.clone(),
            children: build_children(rows, row.id),
            ..Default::default()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_the_parent_child_tree() {
        let raw = "2\t0\t0\tSCAN TABLE users\n\
                   3\t0\t0\tUSE TEMP B-TREE FOR ORDER BY\n\
                   4\t2\t0\tUSING INDEX users_name";
        let plan = parse(raw).expect("parses");
        // Two id=0 children wrap into one synthetic root.
        assert_eq!(plan.root.operation, "Query Plan");
        assert_eq!(plan.root.children.len(), 2);
        let scan = &plan.root.children[0];
        assert_eq!(scan.operation, "SCAN TABLE users");
        assert_eq!(scan.children[0].operation, "USING INDEX users_name");
    }

    #[test]
    fn a_single_root_is_not_wrapped() {
        let plan = parse("2\t0\t0\tSCAN TABLE users").expect("parses");
        assert_eq!(plan.root.operation, "SCAN TABLE users");
    }

    #[test]
    fn empty_input_is_none() {
        assert!(parse("").is_none());
    }
}
