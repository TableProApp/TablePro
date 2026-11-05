use std::collections::{BTreeSet, HashMap};

use crate::meta::TableRef;
use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

use super::{DumpObject, DumpObjectKind, DumpTable};

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

/// The objects' positions with each one after the others its text names.
/// A name written with its schema matches only that schema's object; a
/// bare one matches any of that name, so a name that is also a column's
/// can add an edge that is not there, and a cycle that makes keeps those
/// objects in the order they came.
#[cfg(test)]
fn order_programs(objects: &[&DumpObject], grammar: SqlGrammar) -> Vec<usize> {
    stable_topological(&mention_edges(objects, grammar)).0
}

/// What is made before the rows, and what after the keys and indexes.
///
/// `before` is every object of the pre-data section, the tables among
/// them in the order their rows load, and `after` the keys, checks and
/// indexes the rows come before. A view or routine one of those names,
/// through a DEFAULT, a CHECK, a generated column, a domain or an index
/// expression, is made with the tables, and so is whatever that one
/// names in turn. A materialized view never is: its rows come
/// from the tables', and ClickHouse's would take each row loaded after
/// it again. Each group is put in the order its objects name each other
/// in, ties kept as they came.
pub(super) fn creation_order<'a>(
    before: &[&'a DumpObject],
    programs: &[&'a DumpObject],
    after: &[&'a DumpObject],
    grammar: SqlGrammar,
) -> (Vec<&'a DumpObject>, Vec<&'a DumpObject>) {
    let all: Vec<&DumpObject> = before.iter().chain(programs).chain(after).copied().collect();
    let made = before.len() + programs.len();
    let parents = mention_edges(&all, grammar);
    let mut early: Vec<bool> = (0..made).map(|position| position < before.len()).collect();
    let mut pending: Vec<usize> = (0..before.len()).chain(made..all.len()).collect();
    while let Some(node) = pending.pop() {
        for &parent in &parents[node] {
            let movable = parent < made && all[parent].kind != DumpObjectKind::MaterializedView;
            if movable && !early[parent] {
                early[parent] = true;
                pending.push(parent);
            }
        }
    }
    let group = |wanted: bool| {
        let members: Vec<usize> = (0..made).filter(|&position| early[position] == wanted).collect();
        let local: HashMap<usize, usize> = members
            .iter()
            .enumerate()
            .map(|(at, &position)| (position, at))
            .collect();
        let edges: Vec<Vec<usize>> = members
            .iter()
            .map(|&position| {
                parents[position]
                    .iter()
                    .filter_map(|parent| local.get(parent).copied())
                    .collect()
            })
            .collect();
        stable_topological(&edges)
            .0
            .into_iter()
            .map(|at| all[members[at]])
            .collect::<Vec<_>>()
    };
    (group(true), group(false))
}

/// For each object, the others its text names.
fn mention_edges(objects: &[&DumpObject], grammar: SqlGrammar) -> Vec<Vec<usize>> {
    let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
    for (position, object) in objects.iter().enumerate() {
        by_name.entry(object.name.to_lowercase()).or_default().push(position);
    }
    let schema_of = |position: usize| objects[position].schema.as_deref().map(str::to_lowercase);
    let edges: Vec<Vec<usize>> = objects
        .iter()
        .enumerate()
        .map(|(position, object)| {
            let mut parents = BTreeSet::new();
            for (schema, name) in mentions(object, grammar) {
                for &other in by_name.get(&name).into_iter().flatten() {
                    let same_schema = schema.is_none() || schema == schema_of(other);
                    if other != position && same_schema {
                        parents.insert(other);
                    }
                }
            }
            parents.into_iter().collect()
        })
        .collect();
    edges
}

/// The names the object's statements hold, each with the schema written
/// before it, unquoted and in lower case. Left out: the object's own name
/// where its CREATE states it, a name an `AS` gives (a column or table
/// alias), and a schema written before a dot.
fn mentions(object: &DumpObject, grammar: SqlGrammar) -> Vec<(Option<String>, String)> {
    let own = object.name.to_lowercase();
    let own_schema = object.schema.as_deref().map(str::to_lowercase);
    let mut found = Vec::new();
    let mut declared = false;
    for statement in &object.statements {
        let plan = ScriptPlan::build(&statement.sql, grammar, LexicalSettings::default_for(grammar));
        let tokens: Vec<(ScriptTokenKind, &str)> = plan
            .tokens(0..statement.sql.len())
            .filter(|token| !token.kind.is_trivia())
            .filter_map(|token| statement.sql.get(token.range.clone()).map(|text| (token.kind, text)))
            .collect();
        let name_at = |at: usize| match tokens.get(at) {
            Some((ScriptTokenKind::Word, text)) => Some(text.to_lowercase()),
            Some((ScriptTokenKind::QuotedIdentifier, text)) => Some(unquote(text).to_lowercase()),
            _ => None,
        };
        let is_dot = |at: usize| matches!(tokens.get(at), Some((ScriptTokenKind::Punct, ".")));
        let is_as = |at: usize| matches!(tokens.get(at), Some((ScriptTokenKind::Word, text)) if text.eq_ignore_ascii_case("AS"));
        for at in 0..tokens.len() {
            let Some(name) = name_at(at) else {
                continue;
            };
            if is_dot(at + 1) || (at > 0 && is_as(at - 1)) {
                continue;
            }
            let schema = (at >= 2 && is_dot(at - 1)).then(|| name_at(at - 2)).flatten();
            if !declared && name == own && (schema.is_none() || schema == own_schema) {
                declared = true;
                continue;
            }
            found.push((schema, name));
        }
    }
    found
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
    fn a_view_named_like_one_in_another_schema_follows_the_one_it_reads() {
        let schema_view = |schema: &str, sql: &str| {
            DumpObject::new(
                DumpObjectKind::View,
                DumpSection::Programs,
                Some(schema.to_owned()),
                "v",
                vec![DumpStatement::new(sql)],
            )
        };
        let objects = [
            schema_view("a", "CREATE VIEW a.v AS SELECT * FROM z.v"),
            schema_view("z", "CREATE VIEW z.v AS SELECT 1 AS n"),
        ];
        let refs: Vec<&DumpObject> = objects.iter().collect();

        assert_eq!(order_programs(&refs, SqlGrammar::PostgreSql), [1, 0]);
    }

    #[test]
    fn a_routine_a_table_calls_is_made_with_the_tables_after_what_it_reads() {
        let routine = DumpObject::new(
            DumpObjectKind::Function,
            DumpSection::Programs,
            None,
            "total",
            vec![DumpStatement::new("CREATE MACRO total() AS (SELECT sum(i) FROM base)")],
        );
        let base = DumpObject::table(
            TableRef::unqualified("base"),
            vec![DumpStatement::new("CREATE TABLE base (i int)")],
        );
        let uses = DumpObject::table(
            TableRef::unqualified("uses"),
            vec![DumpStatement::new("CREATE TABLE uses (n int DEFAULT total())")],
        );
        let other = view("other", "CREATE VIEW other AS SELECT * FROM base");

        let (early, late) = creation_order(&[&uses, &base], &[&routine, &other], &[], SqlGrammar::DuckDb);

        let named = |objects: &[&DumpObject]| objects.iter().map(|object| object.name.clone()).collect::<Vec<_>>();
        assert_eq!(named(&early), ["base", "total", "uses"]);
        assert_eq!(named(&late), ["other"]);
    }

    #[test]
    fn a_view_a_macro_before_the_rows_reads_is_made_before_it() {
        let reads = DumpObject::new(
            DumpObjectKind::Function,
            DumpSection::BeforeData,
            None,
            "m",
            vec![DumpStatement::new("CREATE MACRO m() AS (SELECT n FROM v)")],
        );
        let source = view("v", "CREATE VIEW v AS SELECT 1 AS n");

        let (early, late) = creation_order(&[&reads], &[&source], &[], SqlGrammar::DuckDb);

        let named = |objects: &[&DumpObject]| objects.iter().map(|object| object.name.clone()).collect::<Vec<_>>();
        assert_eq!(named(&early), ["v", "m"]);
        assert!(late.is_empty());
    }

    #[test]
    fn a_routine_a_check_after_the_rows_calls_is_made_before_the_rows() {
        let routine = DumpObject::new(
            DumpObjectKind::Function,
            DumpSection::Programs,
            Some("dbo".to_owned()),
            "in_stock",
            vec![DumpStatement::new(
                "CREATE FUNCTION dbo.in_stock(@id int) RETURNS bit WITH SCHEMABINDING AS \
                 BEGIN RETURN (SELECT 1 FROM dbo.stock WHERE id = @id) END",
            )],
        );
        let stock = DumpObject::table(
            TableRef::new(Some("dbo".to_owned()), "stock".to_owned()),
            vec![DumpStatement::new("CREATE TABLE dbo.stock (id int)")],
        );
        let check = DumpObject::new(
            DumpObjectKind::Constraint,
            DumpSection::AfterData,
            Some("dbo".to_owned()),
            "ck_stock",
            vec![DumpStatement::new(
                "ALTER TABLE dbo.orders ADD CONSTRAINT ck_stock CHECK (dbo.in_stock(item) = 1)",
            )],
        );
        let totals = DumpObject::new(
            DumpObjectKind::MaterializedView,
            DumpSection::Programs,
            Some("dbo".to_owned()),
            "item",
            vec![DumpStatement::new(
                "CREATE MATERIALIZED VIEW dbo.item AS SELECT id FROM dbo.stock",
            )],
        );

        let (early, late) = creation_order(&[&stock], &[&totals, &routine], &[&check], SqlGrammar::MsSql);

        let named = |objects: &[&DumpObject]| objects.iter().map(|object| object.name.clone()).collect::<Vec<_>>();
        assert_eq!(named(&early), ["stock", "in_stock"]);
        assert_eq!(named(&late), ["item"]);
    }

    #[test]
    fn a_column_alias_is_not_a_reference() {
        let objects = [
            view("a", "CREATE VIEW a AS SELECT * FROM z"),
            view("z", "CREATE VIEW z AS SELECT 1 AS a"),
        ];
        let refs: Vec<&DumpObject> = objects.iter().collect();

        assert_eq!(order_programs(&refs, SqlGrammar::DuckDb), [1, 0]);
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
