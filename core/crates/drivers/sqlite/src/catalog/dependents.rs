use std::collections::HashSet;

use tablepro_core::ddl::{SchemaObjectKind, SchemaObjectSource};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// One row of `sqlite_schema` that might have to be replayed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SchemaRow {
    pub kind: SchemaObjectKind,
    pub name: String,
    pub table: String,
    pub sql: String,
}

/// The objects a rebuild of `table` has to recreate, in schema order.
///
/// Dropping a table drops its own indexes and triggers. A view, or a
/// trigger on another table, only names it in its SQL, and breaks when
/// the table is gone for a moment, so those are found by the name in
/// their token stream. A view that names a kept view is kept too.
pub(crate) fn select_dependents(table: &str, rows: Vec<SchemaRow>) -> Vec<SchemaObjectSource> {
    let mut names: Vec<String> = vec![table.to_owned()];
    let mut kept = vec![false; rows.len()];
    let mentions: Vec<HashSet<String>> = rows.iter().map(|row| words(&row.sql)).collect();

    loop {
        let mut grew = false;
        for (index, row) in rows.iter().enumerate() {
            if kept[index] || !keeps(row, &mentions[index], table, &names) {
                continue;
            }
            kept[index] = true;
            if row.kind == SchemaObjectKind::View {
                names.push(row.name.clone());
                grew = true;
            }
        }
        if !grew {
            break;
        }
    }

    rows.into_iter()
        .zip(kept)
        .filter(|(_, kept)| *kept)
        .map(|(row, _)| SchemaObjectSource {
            kind: row.kind,
            name: row.name,
            table: row.table,
            sql: row.sql,
        })
        .collect()
}

fn keeps(row: &SchemaRow, mentions: &HashSet<String>, table: &str, names: &[String]) -> bool {
    let owned_by_table = row.table.eq_ignore_ascii_case(table);
    match row.kind {
        SchemaObjectKind::Index | SchemaObjectKind::Trigger if owned_by_table => true,
        SchemaObjectKind::Index => false,
        SchemaObjectKind::Trigger | SchemaObjectKind::View => {
            names.iter().any(|name| mentions.contains(&name.to_lowercase()))
        }
    }
}

/// Every identifier the SQL names, lowercased and unquoted. A name
/// inside a string literal or a comment is not a reference.
fn words(sql: &str) -> HashSet<String> {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    plan.tokens(0..sql.len())
        .filter_map(|token| {
            let text = sql.get(token.range.clone())?;
            match token.kind {
                ScriptTokenKind::Word => Some(text.to_lowercase()),
                ScriptTokenKind::QuotedIdentifier => Some(unquote(text).to_lowercase()),
                _ => None,
            }
        })
        .collect()
}

/// `"a""b"`, `` `a``b` `` and `[a]` all name the same identifier SQLite
/// would read.
fn unquote(text: &str) -> String {
    let mut characters = text.chars();
    let (Some(open), Some(_)) = (characters.next(), characters.next_back()) else {
        return text.to_owned();
    };
    let inner = characters.as_str();
    match open {
        '[' => inner.to_owned(),
        quote => inner.replace(&format!("{quote}{quote}"), &quote.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(kind: SchemaObjectKind, name: &str, table: &str, sql: &str) -> SchemaRow {
        SchemaRow {
            kind,
            name: name.to_owned(),
            table: table.to_owned(),
            sql: sql.to_owned(),
        }
    }

    fn names(selected: &[SchemaObjectSource]) -> Vec<&str> {
        selected.iter().map(|object| object.name.as_str()).collect()
    }

    #[test]
    fn sqlite_dependents_include_views_and_foreign_triggers_transitively() {
        let rows = vec![
            row(
                SchemaObjectKind::Index,
                "orders_total",
                "orders",
                "CREATE INDEX orders_total ON orders (total)",
            ),
            row(
                SchemaObjectKind::Index,
                "people_name",
                "people",
                "CREATE INDEX people_name ON people (name)",
            ),
            row(
                SchemaObjectKind::View,
                "big_orders",
                "big_orders",
                "CREATE VIEW big_orders AS SELECT * FROM \"Orders\" WHERE total > 100",
            ),
            row(
                SchemaObjectKind::View,
                "big_order_count",
                "big_order_count",
                "CREATE VIEW big_order_count AS SELECT count(*) FROM [big_orders]",
            ),
            row(
                SchemaObjectKind::Trigger,
                "people_audit",
                "people",
                "CREATE TRIGGER people_audit AFTER DELETE ON people BEGIN DELETE FROM `orders` WHERE person = old.id; END",
            ),
            row(
                SchemaObjectKind::Trigger,
                "orders_log",
                "orders",
                "CREATE TRIGGER orders_log AFTER INSERT ON orders BEGIN SELECT 1; END",
            ),
            row(
                SchemaObjectKind::View,
                "people_only",
                "people_only",
                "CREATE VIEW people_only AS SELECT * FROM people",
            ),
        ];

        let selected = select_dependents("orders", rows);

        assert_eq!(
            names(&selected),
            [
                "orders_total",
                "big_orders",
                "big_order_count",
                "people_audit",
                "orders_log"
            ]
        );
    }

    #[test]
    fn sqlite_dependents_ignore_name_inside_string_literal() {
        let rows = vec![
            row(
                SchemaObjectKind::View,
                "labels",
                "labels",
                "CREATE VIEW labels AS SELECT 'orders' AS name /* orders */ FROM people",
            ),
            row(
                SchemaObjectKind::Trigger,
                "note",
                "people",
                "CREATE TRIGGER note AFTER INSERT ON people BEGIN SELECT 'orders'; END",
            ),
        ];

        assert!(select_dependents("orders", rows).is_empty());
    }

    #[test]
    fn a_quoted_name_reads_as_the_identifier_it_spells() {
        assert_eq!(unquote("\"a\"\"b\""), "a\"b");
        assert_eq!(unquote("`a``b`"), "a`b");
        assert_eq!(unquote("[a b]"), "a b");
    }
}
