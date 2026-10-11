use relm4::{gtk, gtk::prelude::*};

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PlanNode {
    pub(crate) depth: usize,
    pub(crate) title: String,
    pub(crate) cost: Option<f64>,
    pub(crate) rows: Option<f64>,
    pub(crate) details: Vec<String>,
}

fn number_after(text: &str, key: &str) -> Option<f64> {
    let start = text.find(key)? + key.len();
    let rest = &text[start..];
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn postgres_node(depth: usize, text: &str) -> PlanNode {
    let (title, stats) = match text.find("(cost=") {
        Some(at) => (text[..at].trim(), &text[at..]),
        None => (text.trim(), ""),
    };
    let cost = stats
        .find("..")
        .and_then(|at| number_after(&stats[at..], ".."))
        .filter(|_| stats.starts_with("(cost="));
    PlanNode {
        depth,
        title: title.to_string(),
        cost,
        rows: number_after(stats, "rows="),
        details: Vec::new(),
    }
}

fn parse_postgres(text: &str) -> Vec<PlanNode> {
    let mut nodes: Vec<PlanNode> = Vec::new();
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let indent = line.len() - line.trim_start().len();
        let body = line.trim_start();
        if let Some(rest) = body.strip_prefix("->") {
            nodes.push(postgres_node((indent + 4) / 6, rest.trim_start()));
        } else if nodes.is_empty() {
            nodes.push(postgres_node(0, body));
        } else if let Some(last) = nodes.last_mut() {
            last.details.push(body.to_string());
        }
    }
    nodes
}

fn parse_sqlite(text: &str) -> Vec<PlanNode> {
    let mut depths: Vec<(u64, usize)> = Vec::new();
    let mut nodes = Vec::new();
    for line in text.lines() {
        let parts: Vec<&str> = line.splitn(4, " | ").collect();
        let [id, parent, _, detail] = parts.as_slice() else {
            return Vec::new();
        };
        let (Ok(id), Ok(parent)) = (id.trim().parse::<u64>(), parent.trim().parse::<u64>()) else {
            return Vec::new();
        };
        let depth = depths
            .iter()
            .find(|(known, _)| *known == parent)
            .map_or(0, |(_, depth)| depth + 1);
        depths.push((id, depth));
        nodes.push(PlanNode {
            depth,
            title: detail.trim().to_string(),
            cost: None,
            rows: None,
            details: Vec::new(),
        });
    }
    nodes
}

pub(crate) fn parse_plan(text: &str) -> Vec<PlanNode> {
    let sqlite = parse_sqlite(text);
    if !sqlite.is_empty() {
        return sqlite;
    }
    let postgres = parse_postgres(text);
    if postgres.iter().any(|node| node.cost.is_some()) {
        postgres
    } else {
        Vec::new()
    }
}

pub(crate) fn build_tree(nodes: &[PlanNode]) -> gtk::Widget {
    let list = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    let max_cost = nodes.iter().filter_map(|node| node.cost).fold(0.0_f64, f64::max);
    for node in nodes {
        let row = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .margin_start(node.depth as i32 * 18)
            .build();
        let title = gtk::Label::builder()
            .label(&node.title)
            .xalign(0.0)
            .wrap(true)
            .selectable(true)
            .build();
        row.append(&title);
        if let Some(cost) = node.cost
            && max_cost > 0.0
        {
            let bar = gtk::ProgressBar::builder()
                .fraction((cost / max_cost).clamp(0.0, 1.0))
                .build();
            let rows = node.rows.map(|rows| format!(", ~{rows:.0} rows")).unwrap_or_default();
            bar.set_tooltip_text(Some(&format!("{} {cost:.2}{rows}", crate::tr!("Estimated cost"))));
            row.append(&bar);
        }
        for detail in &node.details {
            let label = gtk::Label::builder()
                .label(detail)
                .xalign(0.0)
                .wrap(true)
                .selectable(true)
                .build();
            label.add_css_class("dim-label");
            label.add_css_class("caption");
            row.append(&label);
        }
        list.append(&row);
    }
    list.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;

    const POSTGRES: &str = "Hash Join  (cost=10.00..120.50 rows=100 width=8)\n  Hash Cond: (a.id = b.id)\n  ->  Seq Scan on a  (cost=0.00..60.00 rows=1000 width=4)\n        Filter: (x > 1)\n  ->  Hash  (cost=5.00..5.00 rows=10 width=4)\n        ->  Index Scan using b_pkey on b  (cost=0.15..5.00 rows=10 width=4)\nPlanning Time: 0.1 ms";

    #[test]
    fn a_postgres_text_plan_becomes_a_tree_with_costs_rows_and_details() {
        let nodes = parse_plan(POSTGRES);
        let shape: Vec<(usize, &str)> = nodes.iter().map(|node| (node.depth, node.title.as_str())).collect();
        assert_eq!(
            shape,
            [
                (0, "Hash Join"),
                (1, "Seq Scan on a"),
                (1, "Hash"),
                (2, "Index Scan using b_pkey on b")
            ]
        );
        assert_eq!(nodes[0].cost, Some(120.5));
        assert_eq!(nodes[1].rows, Some(1000.0));
        assert_eq!(nodes[0].details, ["Hash Cond: (a.id = b.id)"]);
        assert_eq!(nodes[1].details, ["Filter: (x > 1)"]);
        assert!(nodes[3].details.contains(&"Planning Time: 0.1 ms".to_string()));
    }

    #[test]
    fn a_sqlite_query_plan_nests_by_parent_id() {
        let nodes = parse_plan(
            "2 | 0 | 0 | SCAN orders\n5 | 0 | 0 | SEARCH customers USING INTEGER PRIMARY KEY (rowid=?)\n7 | 5 | 0 | USE TEMP B-TREE FOR ORDER BY",
        );
        let depths: Vec<usize> = nodes.iter().map(|node| node.depth).collect();
        assert_eq!(depths, [0, 0, 1]);
        assert_eq!(nodes[2].title, "USE TEMP B-TREE FOR ORDER BY");
    }

    #[test]
    fn text_that_is_not_a_known_plan_stays_text_only() {
        assert!(parse_plan("Seq Scan on a").is_empty());
        assert!(parse_plan("(empty plan)").is_empty());
        assert!(parse_plan("1 | MySQL | table").is_empty());
        assert!(parse_plan("").is_empty());
    }
}
