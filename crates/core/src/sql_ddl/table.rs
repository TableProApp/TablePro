use crate::query::{ForeignKeyInfo, IndexInfo};
use crate::sql_dialect::quote_ident;

use super::index_fk::{build_add_foreign_key, build_create_index};
use super::types::{
    BuildDdlError, DraftColumn, column_comment_statement, qualified_table, render_column_definition, sql_literal,
    validate_table,
};

/// Build CREATE TABLE plus secondary CREATE INDEX / ADD FOREIGN KEY
/// statements as a single ordered Vec ready for execution. The
/// table itself is created first; indexes and FKs follow because
/// some drivers require the table to exist before constraints can
/// reference it.
pub fn build_create_table(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[DraftColumn],
    indexes: &[IndexInfo],
    fks: &[ForeignKeyInfo],
) -> Result<Vec<String>, BuildDdlError> {
    validate_table(table)?;
    if columns.is_empty() {
        return Err(BuildDdlError::NoColumns);
    }
    let pk_count = columns.iter().filter(|c| c.primary_key).count();
    let inline_pk = pk_count == 1;

    let mut col_defs: Vec<String> = Vec::with_capacity(columns.len() + 1);
    for col in columns {
        col_defs.push(render_column_definition(driver_id, col, inline_pk)?);
    }
    if pk_count > 1 {
        let pk_cols: Vec<String> = columns
            .iter()
            .filter(|c| c.primary_key)
            .map(|c| quote_ident(driver_id, &c.name))
            .collect();
        col_defs.push(format!("PRIMARY KEY ({})", pk_cols.join(", ")));
    }

    let mut out = Vec::with_capacity(1 + indexes.len() + fks.len());

    let create_sql = format!(
        "CREATE TABLE {} (\n  {}\n)",
        qualified_table(driver_id, schema, table),
        col_defs.join(",\n  ")
    );
    out.push(create_sql);

    for column in columns {
        if column.comment.is_some()
            && let Some(comment_stmt) = column_comment_statement(driver_id, schema, table, column)?
        {
            out.push(comment_stmt);
        }
    }

    for index in indexes {
        if index.primary {
            // Primary index lives on the inline PK constraint above —
            // emitting it again would error.
            continue;
        }
        out.push(build_create_index(driver_id, schema, table, index)?);
    }

    if !fks.is_empty() && driver_id == "sqlite" {
        // SQLite enforces FK only when this PRAGMA is enabled per
        // connection. Emitting it as the first FK statement makes the
        // CREATE TABLE flow self-contained.
        out.push("PRAGMA foreign_keys = ON".into());
    }
    for fk in fks {
        out.push(build_add_foreign_key(driver_id, schema, table, fk)?);
    }

    Ok(out)
}

pub fn build_drop_table(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    if_exists: bool,
    cascade: bool,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    let mut parts = vec!["DROP TABLE".to_string()];
    if if_exists {
        parts.push("IF EXISTS".into());
    }
    parts.push(qualified_table(driver_id, schema, table));
    if cascade && driver_id == "postgres" {
        parts.push("CASCADE".into());
    }
    // MySQL / SQLite ignore CASCADE (their FK enforcement is driver-
    // side); we don't emit it to keep the generated SQL portable.
    Ok(parts.join(" "))
}

pub fn build_rename_table(
    driver_id: &str,
    schema: Option<&str>,
    old_name: &str,
    new_name: &str,
) -> Result<String, BuildDdlError> {
    validate_table(old_name)?;
    validate_table(new_name)?;
    if driver_id == "mssql" {
        // sp_rename's arguments are SQL string literals, not
        // identifiers, and the bare @newname isn't quoted at all.
        let old_qualified = sql_literal(&qualified_table(driver_id, schema, old_name));
        let new_bare = sql_literal(new_name.trim());
        return Ok(format!("EXEC sp_rename '{}', '{}'", old_qualified, new_bare));
    }
    Ok(format!(
        "ALTER TABLE {} RENAME TO {}",
        qualified_table(driver_id, schema, old_name),
        quote_ident(driver_id, new_name)
    ))
}
