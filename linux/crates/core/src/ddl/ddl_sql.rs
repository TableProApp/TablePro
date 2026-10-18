//! The pieces of DDL most engines spell alike, each written through the
//! engine's own dialect.

use super::BuildDdlError;
use crate::column::{ColumnDefault, ColumnType};
use crate::dialect::SqlDialect;
use crate::foreign_key_info::ForeignKeyInfo;
use crate::meta::{IndexInfo, IndexKey, TableRef};

/// A literal default through the dialect's literal, and an expression as
/// the catalogue or the engine's parser gave it. `None` for no default.
pub fn default_sql(
    dialect: &dyn SqlDialect,
    column: &str,
    default: &ColumnDefault,
    column_type: &ColumnType,
) -> Result<Option<String>, BuildDdlError> {
    match default {
        ColumnDefault::None => Ok(None),
        ColumnDefault::Literal(value) => {
            dialect
                .literal(value, column_type)
                .map(Some)
                .map_err(|error| BuildDdlError::Literal {
                    column: column.to_owned(),
                    error,
                })
        }
        ColumnDefault::Expression(expression) => Ok(Some(expression.as_sql().to_owned())),
    }
}

/// `expression` inside one pair of parentheses. The catalogue hands back
/// SQL Server and MySQL defaults already wrapped, and wrapping them again
/// would grow the text on every round trip.
pub fn parenthesized(expression: &str) -> String {
    let text = expression.trim();
    match wrapped_once(text) {
        true => text.to_owned(),
        false => format!("({text})"),
    }
}

fn wrapped_once(text: &str) -> bool {
    if !text.starts_with('(') || !text.ends_with(')') {
        return false;
    }
    let mut depth = 0usize;
    let mut quote: Option<char> = None;
    for (index, character) in text.char_indices() {
        match (quote, character) {
            (Some(open), _) if character == open => quote = None,
            (Some(_), _) => {}
            (None, '\'' | '"' | '`' | '[') => quote = Some(if character == '[' { ']' } else { character }),
            (None, '(') => depth += 1,
            (None, ')') => {
                depth = depth.saturating_sub(1);
                if depth == 0 && index + 1 < text.len() {
                    return false;
                }
            }
            (None, _) => {}
        }
    }
    depth == 0
}

pub fn column_list(dialect: &dyn SqlDialect, columns: &[String]) -> String {
    columns
        .iter()
        .map(|column| dialect.quote_identifier(column))
        .collect::<Vec<_>>()
        .join(", ")
}

/// An index's keys inside its parentheses. An expression key came from
/// the catalogue, and goes in parentheses of its own, which every engine
/// with expression keys reads as one key.
pub fn index_keys_sql(dialect: &dyn SqlDialect, index: &IndexInfo) -> String {
    index
        .keys
        .iter()
        .map(|key| {
            let direction = if key.descending() { " DESC" } else { "" };
            match key {
                IndexKey::Column { name, .. } => format!("{}{direction}", dialect.quote_identifier(name)),
                IndexKey::Expression { sql, .. } => format!("{}{direction}", parenthesized(sql)),
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// `CREATE [UNIQUE] INDEX name ON table (keys) [WHERE predicate]`, with
/// the table qualified and the index name bare, which is how PostgreSQL,
/// MySQL and SQL Server read it.
pub fn create_index_sql(dialect: &dyn SqlDialect, table: &TableRef, index: &IndexInfo) -> String {
    let unique = if index.unique { "UNIQUE " } else { "" };
    let mut sql = format!(
        "CREATE {unique}INDEX {} ON {} ({})",
        dialect.quote_identifier(&index.name),
        dialect.qualify(table),
        index_keys_sql(dialect, index)
    );
    if let Some(predicate) = &index.predicate {
        sql.push_str(&format!(" WHERE {predicate}"));
    }
    sql
}

/// `CONSTRAINT name FOREIGN KEY (...) REFERENCES table (...)` and its
/// actions. A key with no schema of its own references the table's.
pub fn foreign_key_sql(dialect: &dyn SqlDialect, table: &TableRef, key: &ForeignKeyInfo) -> String {
    let schema = key.ref_schema.clone().or_else(|| table.schema.clone());
    let referenced = TableRef::new(schema, key.ref_table.clone());
    let mut sql = format!(
        "CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {} ({})",
        dialect.quote_identifier(&key.name),
        column_list(dialect, &key.columns),
        dialect.qualify(&referenced),
        column_list(dialect, &key.ref_columns)
    );
    for (clause, action) in [("ON DELETE", key.on_delete), ("ON UPDATE", key.on_update)] {
        if let Some(action) = action.filter(|action| !action.is_default()) {
            sql.push_str(&format!(" {clause} {}", action.as_sql()));
        }
    }
    sql
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_expression_is_wrapped_once() {
        assert_eq!(parenthesized("getdate()"), "(getdate())");
        assert_eq!(parenthesized("(getdate())"), "(getdate())");
        assert_eq!(parenthesized("(a) + (b)"), "((a) + (b))");
        assert_eq!(parenthesized("(N')(')"), "(N')(')");
        assert_eq!(parenthesized(" now() "), "(now())");
    }
}
