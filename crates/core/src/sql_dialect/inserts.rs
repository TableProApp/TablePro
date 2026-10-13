use super::{BuildSqlError, placeholder_for, quote_ident, text_cast_placeholder};
use crate::{ColumnInfo, Value};

pub fn build_insert_from_draft(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    build_insert_from_draft_touched(driver_id, schema, table, columns, values, &[])
}

pub fn build_insert_from_draft_touched(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    values: &[Value],
    touched: &[bool],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    if columns.len() != values.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: values.len(),
        });
    }
    let mut col_idents: Vec<String> = Vec::new();
    let mut placeholders: Vec<String> = Vec::new();
    let mut params: Vec<Value> = Vec::new();
    for (i, col) in columns.iter().enumerate() {
        let typed = touched.get(i).copied().unwrap_or(false);
        let value_is_null = matches!(values[i], Value::Null);
        if col.is_generated || (col.is_auto_increment && (!typed || value_is_null)) {
            continue;
        }
        if value_is_null && !typed && col.default_value.is_some() {
            continue;
        }
        col_idents.push(quote_ident(driver_id, &col.name));
        let placeholder = placeholder_for(driver_id, params.len());
        let value_sql = if driver_id == "postgres" {
            text_cast_placeholder(col, &values[i], placeholder)
        } else {
            placeholder
        };
        placeholders.push(value_sql);
        params.push(values[i].clone());
    }
    if col_idents.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    let qualified = match schema {
        Some(s) => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
        None => quote_ident(driver_id, table),
    };
    let sql = format!(
        "INSERT INTO {} ({}) VALUES ({})",
        qualified,
        col_idents.join(", "),
        placeholders.join(", ")
    );
    Ok((sql, params))
}
