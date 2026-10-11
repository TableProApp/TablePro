use crate::query::{ForeignKeyInfo, IndexInfo};
use crate::sql_dialect::quote_ident;

use super::types::{BuildDdlError, qualified_table, validate_fk_action, validate_table};

pub fn build_create_index(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    index: &IndexInfo,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    if index.name.trim().is_empty() {
        return Err(BuildDdlError::EmptyIndexName);
    }
    if index.columns.is_empty() {
        return Err(BuildDdlError::NoColumns);
    }
    if index.predicate.is_some() {
        return Err(BuildDdlError::PartialIndex);
    }
    let unique = if index.unique { "UNIQUE " } else { "" };
    let cols: Vec<String> = index.columns.iter().map(|c| quote_ident(driver_id, c)).collect();
    let qualified = qualified_table(driver_id, schema, table);
    // MySQL does not accept schema prefix on the index name, and
    // CREATE INDEX scopes to the table by default. Postgres / SQLite
    // accept schema-qualified index names but the table reference
    // already pins the schema.
    Ok(format!(
        "CREATE {unique}INDEX {} ON {} ({})",
        quote_ident(driver_id, &index.name),
        qualified,
        cols.join(", "),
    ))
}

pub fn build_drop_index(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    index_name: &str,
) -> Result<String, BuildDdlError> {
    if index_name.trim().is_empty() {
        return Err(BuildDdlError::EmptyIndexName);
    }
    if driver_id == "mysql" {
        validate_table(table)?;
        // MySQL DROP INDEX needs the table reference; ALTER TABLE
        // form is portable across MySQL versions.
        return Ok(format!(
            "ALTER TABLE {} DROP INDEX {}",
            qualified_table(driver_id, schema, table),
            quote_ident(driver_id, index_name)
        ));
    }
    if driver_id == "mssql" {
        validate_table(table)?;
        // MSSQL indexes are not standalone schema objects: DROP INDEX
        // must always state the owning table via ON <table>.
        return Ok(format!(
            "DROP INDEX IF EXISTS {} ON {}",
            quote_ident(driver_id, index_name),
            qualified_table(driver_id, schema, table)
        ));
    }
    // Postgres + SQLite: schema-qualified index name, no table ref.
    let qualified_index = match schema {
        Some(s) if !s.is_empty() => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, index_name)),
        _ => quote_ident(driver_id, index_name),
    };
    Ok(format!("DROP INDEX IF EXISTS {qualified_index}"))
}

pub fn build_add_foreign_key(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    fk: &ForeignKeyInfo,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    if fk.name.trim().is_empty() {
        return Err(BuildDdlError::EmptyForeignKeyName);
    }
    if fk.columns.is_empty() || fk.ref_columns.is_empty() {
        return Err(BuildDdlError::NoColumns);
    }
    let cols: Vec<String> = fk.columns.iter().map(|c| quote_ident(driver_id, c)).collect();
    let ref_cols: Vec<String> = fk.ref_columns.iter().map(|c| quote_ident(driver_id, c)).collect();
    let ref_table = qualified_table(driver_id, fk.ref_schema.as_deref(), &fk.ref_table);
    let mut clauses = vec![format!(
        "ALTER TABLE {} ADD CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {} ({})",
        qualified_table(driver_id, schema, table),
        quote_ident(driver_id, &fk.name),
        cols.join(", "),
        ref_table,
        ref_cols.join(", "),
    )];
    if let Some(raw) = fk.on_delete.as_deref().filter(|a| !a.is_empty()) {
        let action = validate_fk_action(driver_id, raw)?;
        clauses.push(format!("ON DELETE {action}"));
    }
    if let Some(raw) = fk.on_update.as_deref().filter(|a| !a.is_empty()) {
        let action = validate_fk_action(driver_id, raw)?;
        clauses.push(format!("ON UPDATE {action}"));
    }
    Ok(clauses.join(" "))
}

pub fn build_drop_foreign_key(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    fk_name: &str,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    if fk_name.trim().is_empty() {
        return Err(BuildDdlError::EmptyForeignKeyName);
    }
    let qualified = qualified_table(driver_id, schema, table);
    match driver_id {
        "mysql" => Ok(format!(
            "ALTER TABLE {} DROP FOREIGN KEY {}",
            qualified,
            quote_ident(driver_id, fk_name)
        )),
        "postgres" | "mssql" => Ok(format!(
            "ALTER TABLE {} DROP CONSTRAINT {}",
            qualified,
            quote_ident(driver_id, fk_name)
        )),
        "sqlite" => Err(BuildDdlError::SqliteNotSupported(
            "DROP FOREIGN KEY (requires table rebuild)",
        )),
        other => Err(BuildDdlError::UnsupportedDriver(other.to_string())),
    }
}
