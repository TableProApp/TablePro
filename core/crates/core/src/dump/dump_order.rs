use std::collections::{BTreeSet, HashMap};

use crate::meta::TableRef;
use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

use super::{DumpObject, DumpTable};

/// The tables' positions with every table after those it references,
/// and the tables a reference cycle left in the order they came.
pub(super) fn order_tables(tables: &[DumpTable]) -> (Vec<usize>, Vec<TableRef>) {
    let index: HashMap<&TableRef, usize> = tables
        .iter()
        .enumerate()
        .map(|(position, table)| (&table.table, position))
        .collect();
    let edges: Vec<Vec<usize>> = tables
        .iter()
        .enumerate()
        .map(|(position, table)| {
            table
                .references
                .iter()
                .filter_map(|reference| index.get(reference).copied())
                .filter(|parent| *parent != position)
                .collect()
        })
        .collect();
    let (order, stuck) = stable_topological(&edges);
    let unordered = stuck.iter().map(|&position| tables[position].table.clone()).collect();
    (order, unordered)
}

/// The objects' positions with each one after the others whose names its
/// text mentions. A name that is also a column's can add an edge that is
/// not there; a cycle that makes keeps those objects in the order they
/// came.
pub(super) fn order_programs(objects: &[&DumpObject], grammar: SqlGrammar) -> Vec<usize> {
    let names: Vec<String> = objects.iter().map(|object| object.name.to_lowercase()).collect();
    let mut by_name: HashMap<&str, Vec<usize>> = HashMap::new();
    for (position, name) in names.iter().enumerate() {
        by_name.entry(name.as_str()).or_default().push(position);
    }
    let edges: Vec<Vec<usize>> = objects
        .iter()
        .enumerate()
        .map(|(position, object)| {
            let mut parents = BTreeSet::new();
            for word in mentioned_names(object, grammar) {
                for &other in by_name.get(word.as_str()).into_iter().flatten() {
                    if other != position {
                        parents.insert(other);
                    }
                }
            }
            parents.into_iter().collect()
        })
        .collect();
    stable_topological(&edges).0
}

/// Every identifier the object's statements hold, unquoted and in lower
/// case, past the object's own name where its CREATE states it.
fn mentioned_names(object: &DumpObject, grammar: SqlGrammar) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for statement in &object.statements {
        let plan = ScriptPlan::build(&statement.sql, grammar, LexicalSettings::default_for(grammar));
        for token in plan.tokens(0..statement.sql.len()) {
            let Some(text) = statement.sql.get(token.range.clone()) else {
                continue;
            };
            let name = match token.kind {
                ScriptTokenKind::Word => text.to_lowercase(),
                ScriptTokenKind::QuotedIdentifier => unquote(text).to_lowercase(),
                _ => continue,
            };
            names.insert(name);
        }
    }
    names
}

fn unquote(text: &str) -> &str {
    let mut chars = text.chars();
    match (chars.next(), chars.next_back()) {
        (Some('"'), Some('"')) | (Some('`'), Some('`')) | (Some('['), Some(']')) => {
            text.get(1..text.len() - 1).unwrap_or(text)
        }
        _ => text,
    }
}

/// Kahn's order, taking the earliest ready position each step so an
/// order with nothing to fix stays as it came. `parents[i]` must come
/// before `i`. The positions a cycle leaves follow in their own order.
fn stable_topological(parents: &[Vec<usize>]) -> (Vec<usize>, Vec<usize>) {
    let count = parents.len();
    let mut waiting: Vec<usize> = parents.iter().map(Vec::len).collect();
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); count];
    for (child, list) in parents.iter().enumerate() {
        for &parent in list {
            children[parent].push(child);
        }
    }
    let mut ready: BTreeSet<usize> = (0..count).filter(|&position| waiting[position] == 0).collect();
    let mut order = Vec::with_capacity(count);
    while let Some(next) = ready.pop_first() {
        order.push(next);
        for &child in &children[next] {
            waiting[child] -= 1;
            if waiting[child] == 0 {
                ready.insert(child);
            }
        }
    }
    let placed: BTreeSet<usize> = order.iter().copied().collect();
    let stuck: Vec<usize> = (0..count).filter(|position| !placed.contains(position)).collect();
    order.extend(stuck.iter().copied());
    (order, stuck)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dump::{DumpObjectKind, DumpSection, DumpStatement};

    fn table(name: &str, references: &[&str]) -> DumpTable {
        let mut table = DumpTable::new(TableRef::unqualified(name));
        table.references = references.iter().map(|name| TableRef::unqualified(*name)).collect();
        table
    }

    fn names(tables: &[DumpTable], order: &[usize]) -> Vec<String> {
        order
            .iter()
            .map(|&position| tables[position].table.name.clone())
            .collect()
    }

    #[test]
    fn a_parent_comes_before_the_tables_that_reference_it() {
        let tables = [
            table("lines", &["orders", "products"]),
            table("orders", &["customers"]),
            table("customers", &[]),
            table("products", &[]),
        ];

        let (order, unordered) = order_tables(&tables);

        assert_eq!(names(&tables, &order), ["customers", "orders", "products", "lines"]);
        assert!(unordered.is_empty());
    }

    #[test]
    fn a_self_reference_and_an_unknown_table_do_not_hold_a_table_back() {
        let tables = [table("tree", &["tree", "elsewhere"]), table("a", &[])];

        let (order, unordered) = order_tables(&tables);

        assert_eq!(names(&tables, &order), ["tree", "a"]);
        assert!(unordered.is_empty());
    }

    #[test]
    fn a_cycle_keeps_its_tables_in_their_order_and_names_them() {
        let tables = [table("a", &["b"]), table("b", &["a"]), table("c", &[])];

        let (order, unordered) = order_tables(&tables);

        assert_eq!(names(&tables, &order), ["c", "a", "b"]);
        assert_eq!(unordered, [TableRef::unqualified("a"), TableRef::unqualified("b")]);
    }

    fn view(name: &str, sql: &str) -> DumpObject {
        DumpObject::new(
            DumpObjectKind::View,
            DumpSection::Programs,
            None,
            name,
            vec![DumpStatement::new(sql)],
        )
    }

    #[test]
    fn a_view_follows_the_views_and_routines_it_names() {
        let objects = [
            view("top", "CREATE VIEW top AS SELECT * FROM \"Middle\""),
            view("Middle", "CREATE VIEW \"Middle\" AS SELECT double_it(n) FROM base"),
            view(
                "double_it",
                "CREATE FUNCTION double_it(x int) RETURNS int AS 'SELECT x * 2'",
            ),
            view("base", "CREATE VIEW base AS SELECT 1 AS n"),
        ];
        let refs: Vec<&DumpObject> = objects.iter().collect();

        let order = order_programs(&refs, SqlGrammar::PostgreSql);

        let named: Vec<&str> = order.iter().map(|&position| objects[position].name.as_str()).collect();
        assert_eq!(named, ["double_it", "base", "Middle", "top"]);
    }

    #[test]
    fn a_name_inside_a_string_is_not_a_reference() {
        let objects = [
            view("a", "CREATE VIEW a AS SELECT 'b' AS label"),
            view("b", "CREATE VIEW b AS SELECT * FROM a"),
        ];
        let refs: Vec<&DumpObject> = objects.iter().collect();

        assert_eq!(order_programs(&refs, SqlGrammar::PostgreSql), [0, 1]);
    }
}
