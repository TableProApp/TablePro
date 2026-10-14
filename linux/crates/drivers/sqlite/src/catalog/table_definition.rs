use std::collections::HashMap;

use sqlparser::ast::{ColumnOption, Statement};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::parser::Parser;
use tablepro_core::column::SqlExpression;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;

use crate::ddl::declared_foreign_key_names;

/// One row of the inbound foreign key query: a key column of another
/// table that points at this one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InboundKeyRow {
    pub child: String,
    /// The child's CREATE TABLE, where the key's declared name is.
    pub child_sql: Option<String>,
    pub id: i64,
    pub from: String,
    /// `None` when the key names no columns, which means the parent's
    /// primary key.
    pub to: Option<String>,
}

/// Group key columns into keys, in the order the query returned them.
/// A key that names no parent columns points at `primary_key`.
pub(crate) fn inbound_foreign_keys(
    schema: Option<&str>,
    rows: Vec<InboundKeyRow>,
    primary_key: &[String],
) -> Vec<InboundForeignKey> {
    let mut keys: Vec<InboundForeignKey> = Vec::new();
    let mut positions: HashMap<(String, i64), usize> = HashMap::new();
    let mut unnamed_targets: Vec<bool> = Vec::new();
    let mut names: HashMap<String, Vec<String>> = HashMap::new();
    for row in rows {
        let child_names = names.entry(row.child.clone()).or_insert_with(|| {
            let declared = row.child_sql.as_deref().and_then(declared_foreign_key_names);
            let count = declared.as_ref().map_or(0, Vec::len);
            foreign_key_names(&row.child, declared, count)
        });
        let name = usize::try_from(row.id)
            .ok()
            .and_then(|id| child_names.get(id))
            .cloned()
            .unwrap_or_else(|| foreign_key_name(&row.child, row.id));
        let position = *positions.entry((row.child.clone(), row.id)).or_insert_with(|| {
            keys.push(InboundForeignKey {
                name,
                table: TableRef::new(schema.map(str::to_owned), row.child.clone()),
                columns: Vec::new(),
                referenced_columns: Vec::new(),
            });
            unnamed_targets.push(false);
            keys.len() - 1
        });
        let (Some(key), Some(unnamed)) = (keys.get_mut(position), unnamed_targets.get_mut(position)) else {
            continue;
        };
        key.columns.push(row.from);
        match row.to {
            Some(to) => key.referenced_columns.push(to),
            None => *unnamed = true,
        }
    }
    for (key, unnamed) in keys.iter_mut().zip(unnamed_targets) {
        if unnamed {
            key.referenced_columns = primary_key.to_vec();
        }
    }
    keys
}

/// The name of a key declared without one, made from the child table
/// and the key's position, which stays the same while the schema does.
pub(crate) fn foreign_key_name(table: &str, id: i64) -> String {
    format!("fk_{table}_{id}")
}

/// A name for each of a table's `count` foreign keys, by pragma id. The
/// pragmas do not report the name a CONSTRAINT clause gave a key, so it
/// comes from the table's CREATE TABLE, `declared`. A key without one,
/// or with a name an earlier key took, gets a made-up one.
pub(crate) fn foreign_key_names(table: &str, declared: Option<Vec<Option<String>>>, count: usize) -> Vec<String> {
    let declared = declared.filter(|declared| declared.len() == count).unwrap_or_default();
    let mut names: Vec<String> = Vec::with_capacity(count);
    for id in 0..count {
        let made_up = || foreign_key_name(table, i64::try_from(id).unwrap_or(i64::MAX));
        let name = declared
            .get(id)
            .cloned()
            .flatten()
            .filter(|name| !names.iter().any(|taken| taken.eq_ignore_ascii_case(name)))
            .unwrap_or_else(made_up);
        names.push(name);
    }
    names
}

/// The expressions of the generated columns, read from the table's own
/// CREATE TABLE. The pragmas say a column is generated but not how.
/// The text is the parser's rendering of the expression: the table's
/// source keeps the original spelling for a rebuild.
pub(crate) fn generated_expressions(create_statement: &str) -> HashMap<String, SqlExpression> {
    let Ok(statements) = Parser::parse_sql(&SQLiteDialect {}, create_statement) else {
        tracing::debug!("the CREATE TABLE of a table with generated columns did not parse");
        return HashMap::new();
    };
    let Some(Statement::CreateTable(table)) = statements.into_iter().next() else {
        return HashMap::new();
    };
    table
        .columns
        .into_iter()
        .filter_map(|column| {
            let expression = column.options.into_iter().find_map(|option| match option.option {
                ColumnOption::Generated {
                    generation_expr: Some(expression),
                    ..
                } => Some(expression),
                _ => None,
            })?;
            Some((
                column.name.value,
                SqlExpression::from_catalog_text(expression.to_string()),
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key_row(child: &str, id: i64, from: &str, to: Option<&str>) -> InboundKeyRow {
        InboundKeyRow {
            child: child.to_owned(),
            child_sql: None,
            id,
            from: from.to_owned(),
            to: to.map(str::to_owned),
        }
    }

    #[test]
    fn a_key_without_target_columns_points_at_the_primary_key() {
        let rows = vec![
            key_row("lines", 0, "order_id", None),
            key_row("notes", 0, "order_a", Some("a")),
            key_row("notes", 0, "order_b", Some("b")),
        ];

        let keys = inbound_foreign_keys(None, rows, &["id".to_owned()]);

        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].name, "fk_lines_0");
        assert_eq!(keys[0].table, TableRef::unqualified("lines"));
        assert_eq!(keys[0].referenced_columns, ["id"]);
        assert_eq!(keys[1].columns, ["order_a", "order_b"]);
        assert_eq!(keys[1].referenced_columns, ["a", "b"]);
    }

    #[test]
    fn a_declared_constraint_name_is_the_key_name() {
        let child_sql = "CREATE TABLE lines (a INTEGER CONSTRAINT to_orders REFERENCES orders, b INTEGER REFERENCES \
                         orders, CONSTRAINT to_orders FOREIGN KEY (a) REFERENCES orders)";
        let rows = [(0, "a"), (1, "b"), (2, "a")].map(|(id, from)| InboundKeyRow {
            child_sql: Some(child_sql.to_owned()),
            ..key_row("lines", id, from, None)
        });

        let keys = inbound_foreign_keys(None, rows.to_vec(), &["id".to_owned()]);

        let names: Vec<&str> = keys.iter().map(|key| key.name.as_str()).collect();
        assert_eq!(names, ["to_orders", "fk_lines_1", "fk_lines_2"]);
        assert_eq!(
            foreign_key_names("t", Some(vec![Some("x".to_owned())]), 2),
            ["fk_t_0", "fk_t_1"],
            "a list that does not match the catalogue is not used"
        );
    }

    #[test]
    fn generated_expressions_come_from_the_create_statement() {
        let expressions = generated_expressions(
            "CREATE TABLE t (a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) STORED, c AS (a + 1))",
        );

        assert_eq!(expressions.get("b").map(SqlExpression::as_sql), Some("a * 2"));
        assert_eq!(expressions.get("c").map(SqlExpression::as_sql), Some("a + 1"));
        assert!(!expressions.contains_key("a"));
    }
}
