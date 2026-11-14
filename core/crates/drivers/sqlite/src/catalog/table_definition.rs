use std::collections::{HashMap, HashSet};

use sqlparser::ast::{ColumnOption, Statement};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::parser::Parser;
use tablepro_core::column::SqlExpression;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;
use tablepro_core::{CatalogBudget, DriverError};

// A column of another table's key that points at this one. `to` is None for a key naming no columns, which means
// the parent's primary key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InboundKeyColumn {
    pub id: i64,
    pub seq: i64,
    pub from: String,
    pub to: Option<String>,
}

// One child's keys in pragma id order, each named by its id in `names`. A key naming no parent columns points at
// `primary_key`.
pub(crate) fn inbound_foreign_keys(
    schema: Option<&str>,
    child: &str,
    mut columns: Vec<InboundKeyColumn>,
    names: &[String],
    primary_key: &[String],
    budget: &mut CatalogBudget,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    columns.sort_by_key(|column| (column.id, column.seq));
    let mut keys: Vec<InboundForeignKey> = Vec::new();
    let mut unnamed_targets: Vec<bool> = Vec::new();
    let mut last_id = None;
    for column in columns {
        if last_id != Some(column.id) {
            last_id = Some(column.id);
            let name = usize::try_from(column.id)
                .ok()
                .and_then(|id| names.get(id))
                .cloned()
                .unwrap_or_else(|| foreign_key_name(child, column.id));
            // Each key holds its own copy of the child's name, which can be long.
            keys.push(InboundForeignKey {
                child_compares_alike: true,
                name: budget.keep(name)?,
                table: TableRef::new(
                    budget.keep_optional(schema.map(str::to_owned))?,
                    budget.keep(child.to_owned())?,
                ),
                columns: Vec::new(),
                referenced_columns: Vec::new(),
            });
            unnamed_targets.push(false);
        }
        let (Some(key), Some(unnamed)) = (keys.last_mut(), unnamed_targets.last_mut()) else {
            continue;
        };
        key.columns.push(column.from);
        match column.to {
            Some(to) => key.referenced_columns.push(to),
            None => *unnamed = true,
        }
    }
    for (key, unnamed) in keys.iter_mut().zip(unnamed_targets) {
        if unnamed {
            budget.charge_texts(primary_key)?;
            key.referenced_columns = primary_key.to_vec();
        }
    }
    Ok(keys)
}

/// The name of a key declared without one, made from the child table
/// and the key's position, which stays the same while the schema does.
pub(crate) fn foreign_key_name(table: &str, id: i64) -> String {
    format!("fk_{table}_{id}")
}

// The pragmas do not report the name a CONSTRAINT clause gave a key, so it comes from the CREATE TABLE, `declared`;
// a key without one, or with a name an earlier key took, gets a made-up one.
pub(crate) fn foreign_key_names(
    table: &str,
    declared: Option<Vec<Option<String>>>,
    count: usize,
    budget: &mut CatalogBudget,
) -> Result<Vec<String>, DriverError> {
    let declared = declared.filter(|declared| declared.len() == count).unwrap_or_default();
    let mut names: Vec<String> = Vec::new();
    // Folded as SQLite folds names, so a table with thousands of keys is not checked key against key. Only a
    // declared name can be taken already, so a table that declares none keeps no second copy.
    let mut taken: HashSet<String> = HashSet::new();
    for id in 0..count {
        let made_up = || foreign_key_name(table, i64::try_from(id).unwrap_or(i64::MAX));
        let name = declared
            .get(id)
            .cloned()
            .flatten()
            .filter(|name| !taken.contains(&name.to_ascii_lowercase()))
            .unwrap_or_else(made_up);
        let name = budget.keep(name)?;
        if !declared.is_empty() {
            taken.insert(budget.keep(name.to_ascii_lowercase())?);
        }
        names.push(name);
    }
    for folded in &taken {
        budget.release_text(folded);
    }
    Ok(names)
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

    fn column(id: i64, seq: i64, from: &str, to: Option<&str>) -> InboundKeyColumn {
        InboundKeyColumn {
            id,
            seq,
            from: from.to_owned(),
            to: to.map(str::to_owned),
        }
    }

    fn keys_of(
        child: &str,
        columns: Vec<InboundKeyColumn>,
        child_sql: Option<&str>,
        child_keys: usize,
    ) -> Vec<InboundForeignKey> {
        let mut budget = CatalogBudget::default();
        let declared = child_sql.and_then(crate::ddl::declared_foreign_key_names);
        let names = foreign_key_names(child, declared, child_keys, &mut budget).unwrap();
        inbound_foreign_keys(None, child, columns, &names, &["id".to_owned()], &mut budget).unwrap()
    }

    #[test]
    fn a_key_without_target_columns_points_at_the_primary_key() {
        let lines = keys_of("lines", vec![column(0, 0, "order_id", None)], None, 3);
        let notes = keys_of(
            "notes",
            vec![column(0, 1, "order_b", Some("b")), column(0, 0, "order_a", Some("a"))],
            None,
            3,
        );

        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].name, "fk_lines_0");
        assert_eq!(lines[0].table, TableRef::unqualified("lines"));
        assert_eq!(lines[0].referenced_columns, ["id"]);
        assert_eq!(notes.len(), 1);
        assert_eq!(
            notes[0].columns,
            ["order_a", "order_b"],
            "in key order whatever order they came in"
        );
        assert_eq!(notes[0].referenced_columns, ["a", "b"]);
    }

    #[test]
    fn a_declared_constraint_name_is_the_key_name() {
        let child_sql = "CREATE TABLE lines (a INTEGER CONSTRAINT to_orders REFERENCES orders, b INTEGER REFERENCES \
                         orders, CONSTRAINT to_orders FOREIGN KEY (a) REFERENCES orders)";
        let columns = || {
            vec![
                column(2, 0, "a", None),
                column(0, 0, "a", None),
                column(1, 0, "b", None),
            ]
        };

        let keys = keys_of("lines", columns(), Some(child_sql), 3);

        let names: Vec<&str> = keys.iter().map(|key| key.name.as_str()).collect();
        assert_eq!(names, ["to_orders", "fk_lines_1", "fk_lines_2"]);
        let unsure: Vec<String> = keys_of("lines", columns(), Some(child_sql), 4)
            .into_iter()
            .map(|key| key.name)
            .collect();
        assert_eq!(
            unsure,
            ["fk_lines_0", "fk_lines_1", "fk_lines_2"],
            "names read from text that declares fewer keys than the child has"
        );
        assert_eq!(
            foreign_key_names("t", Some(vec![Some("x".to_owned())]), 2, &mut CatalogBudget::default()),
            Ok(vec!["fk_t_0".to_owned(), "fk_t_1".to_owned()]),
            "a list that does not match the catalogue is not used"
        );
        assert_eq!(
            foreign_key_names(
                "t",
                Some(vec![Some("Same".to_owned()), Some("SAME".to_owned())]),
                2,
                &mut CatalogBudget::default()
            ),
            Ok(vec!["Same".to_owned(), "fk_t_1".to_owned()]),
            "a name an earlier key took, in other case, is not taken again"
        );
    }

    #[test]
    fn copies_of_a_long_primary_key_stop_at_the_budget() {
        let primary_key: Vec<String> = (0..10).map(|column| format!("{column}{}", "k".repeat(1_000))).collect();
        let columns: Vec<InboundKeyColumn> = (0..1_000).map(|id| column(id, 0, "a", None)).collect();
        let mut budget = CatalogBudget::new(tablepro_core::ByteLimit::new(1_000_000).unwrap());

        let names = foreign_key_names("child", None, 1_000, &mut budget).unwrap();
        let read = inbound_foreign_keys(None, "child", columns, &names, &primary_key, &mut budget);

        assert_eq!(read, Err(DriverError::CatalogTooLarge { limit_bytes: 1_000_000 }));
    }

    #[test]
    fn made_up_names_of_a_long_table_stop_at_the_budget() {
        let mut budget = CatalogBudget::new(tablepro_core::ByteLimit::new(1_000_000).unwrap());

        let names = foreign_key_names(&"t".repeat(10_000), None, 1_000, &mut budget);

        assert_eq!(names, Err(DriverError::CatalogTooLarge { limit_bytes: 1_000_000 }));
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
