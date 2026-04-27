//! DDL string builders for CREATE / ALTER / DROP TABLE, CREATE / DROP
//! INDEX, ADD / DROP FOREIGN KEY across MySQL + Postgres + SQLite.
//!
//! Pure SQL-string construction; no async, no I/O. Mirrors the
//! parameterised-by-`driver_id` style of `sql_dialect.rs`. All
//! identifier quoting goes through `sql_dialect::quote_ident`; type
//! names interpolate raw because they're a syntax category, not a
//! string-literal category — the worst case is a driver syntax error,
//! never injection.
//!
//! Statement ordering for a multi-op materialize() is handled by the
//! caller (the StructureChangeTracker). Each builder produces one
//! statement at a time; the caller composes them.

use thiserror::Error;

use crate::query::{ColumnInfo, ForeignKeyInfo, IndexInfo};
use crate::sql_dialect::quote_ident;

#[derive(Debug, Error)]
pub enum BuildDdlError {
    #[error("table name is empty")]
    EmptyTableName,

    #[error("at least one column is required")]
    NoColumns,

    #[error("column name is empty")]
    EmptyColumnName,

    #[error("column type is empty")]
    EmptyColumnType,

    #[error("index name is empty")]
    EmptyIndexName,

    #[error("foreign key name is empty")]
    EmptyForeignKeyName,

    #[error("operation not supported by SQLite: {0}")]
    SqliteNotSupported(&'static str),

    #[error("operation not supported by Postgres: {0}")]
    PostgresNotSupported(&'static str),

    #[error("unsupported driver: {0}")]
    UnsupportedDriver(String),
}

/// User-edited column draft. Carries both the original (loaded from
/// `fetch_columns`) and the in-flight edit. `original` is `None` for
/// newly-added columns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DraftColumn {
    pub original: Option<ColumnInfo>,
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub default_value: Option<String>,
}

impl DraftColumn {
    /// Build a `DraftColumn` from a `ColumnInfo` returned by
    /// `fetch_columns` so the user starts with the live state and
    /// edits diff against `original`.
    pub fn from_info(info: ColumnInfo) -> Self {
        let data_type = info.data_type.clone();
        let nullable = info.nullable;
        let primary_key = info.primary_key;
        let auto_increment = info.is_auto_increment;
        let default_value = info.default_value.clone();
        let name = info.name.clone();
        Self {
            original: Some(info),
            name,
            data_type,
            nullable,
            primary_key,
            auto_increment,
            default_value,
        }
    }
}

fn qualified_table(driver_id: &str, schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) if !s.is_empty() => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
        _ => quote_ident(driver_id, table),
    }
}

fn validate_table(table: &str) -> Result<(), BuildDdlError> {
    if table.trim().is_empty() {
        return Err(BuildDdlError::EmptyTableName);
    }
    Ok(())
}

fn validate_column_name(name: &str) -> Result<(), BuildDdlError> {
    if name.trim().is_empty() {
        return Err(BuildDdlError::EmptyColumnName);
    }
    Ok(())
}

fn validate_column_type(data_type: &str) -> Result<(), BuildDdlError> {
    if data_type.trim().is_empty() {
        return Err(BuildDdlError::EmptyColumnType);
    }
    Ok(())
}

/// Render one inline column definition for a CREATE TABLE statement.
/// PK is rendered inline only for single-column PK; composite PKs are
/// emitted as a table-level constraint by the caller.
fn render_column_definition(driver_id: &str, column: &DraftColumn, inline_pk: bool) -> Result<String, BuildDdlError> {
    validate_column_name(&column.name)?;
    validate_column_type(&column.data_type)?;
    let mut parts = vec![quote_ident(driver_id, &column.name), column.data_type.clone()];

    // SQLite: INTEGER PRIMARY KEY (with optional AUTOINCREMENT) is
    // the canonical rowid alias and is its own paragraph in the
    // grammar. Render that pattern when the user asked for inline PK
    // on a single integer column. AUTOINCREMENT is opt-in (it adds
    // monotonic-id guarantees + sqlite_sequence overhead).
    if driver_id == "sqlite" && inline_pk && column.primary_key {
        parts.push("PRIMARY KEY".into());
        if column.auto_increment {
            parts.push("AUTOINCREMENT".into());
        }
        if !column.nullable {
            parts.push("NOT NULL".into());
        }
        if let Some(default) = column.default_value.as_deref().filter(|d| !d.is_empty()) {
            parts.push(format!("DEFAULT {default}"));
        }
        return Ok(parts.join(" "));
    }

    // Postgres SERIAL / BIGSERIAL when auto_increment is requested on
    // an integer column. SERIAL implies NOT NULL + a sequence default,
    // so don't emit those redundantly. The user-typed type is
    // overridden because `serial` IS the type for that pseudo-pattern.
    if driver_id == "postgres" && column.auto_increment {
        let lower = column.data_type.to_ascii_lowercase();
        let serial_type = if lower.contains("bigint") || lower.contains("int8") {
            "BIGSERIAL"
        } else if lower.contains("smallint") || lower.contains("int2") {
            "SMALLSERIAL"
        } else {
            "SERIAL"
        };
        parts = vec![quote_ident(driver_id, &column.name), serial_type.into()];
        if inline_pk && column.primary_key {
            parts.push("PRIMARY KEY".into());
        }
        return Ok(parts.join(" "));
    }

    if !column.nullable {
        parts.push("NOT NULL".into());
    }
    if let Some(default) = column.default_value.as_deref().filter(|d| !d.is_empty()) {
        parts.push(format!("DEFAULT {default}"));
    }

    if driver_id == "mysql" && column.auto_increment {
        parts.push("AUTO_INCREMENT".into());
    }

    if inline_pk && column.primary_key {
        parts.push("PRIMARY KEY".into());
    }

    Ok(parts.join(" "))
}

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
    if driver_id == "mysql" {
        // MySQL accepts both `ALTER TABLE ... RENAME TO ...` and
        // `RENAME TABLE ... TO ...`. The latter accepts cross-schema
        // moves; the former is enough for our same-schema case.
        return Ok(format!(
            "ALTER TABLE {} RENAME TO {}",
            qualified_table(driver_id, schema, old_name),
            quote_ident(driver_id, new_name)
        ));
    }
    Ok(format!(
        "ALTER TABLE {} RENAME TO {}",
        qualified_table(driver_id, schema, old_name),
        quote_ident(driver_id, new_name)
    ))
}

pub fn build_add_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    let column_def = render_column_definition(driver_id, column, false)?;
    if driver_id == "sqlite" && !column.nullable && column.default_value.as_deref().unwrap_or("").is_empty() {
        // SQLite refuses ADD COLUMN NOT NULL unless the column has a
        // DEFAULT (or is a generated column we don't yet handle).
        // Surface the limit at build time so the UI can show a clear
        // error before sending the statement to the driver.
        return Err(BuildDdlError::SqliteNotSupported("ADD COLUMN NOT NULL without DEFAULT"));
    }
    Ok(format!(
        "ALTER TABLE {} ADD COLUMN {}",
        qualified_table(driver_id, schema, table),
        column_def
    ))
}

pub fn build_drop_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column_name: &str,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    validate_column_name(column_name)?;
    if driver_id == "sqlite" {
        // SQLite added DROP COLUMN in 3.35; we trust the runtime
        // SQLite to enforce. The UI disables the affordance for
        // older runtimes via the same path, but this builder doesn't
        // version-detect — the error surfaces from the driver if the
        // version is too old.
    }
    Ok(format!(
        "ALTER TABLE {} DROP COLUMN {}",
        qualified_table(driver_id, schema, table),
        quote_ident(driver_id, column_name)
    ))
}

pub fn build_rename_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    old_name: &str,
    new_name: &str,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    validate_column_name(old_name)?;
    validate_column_name(new_name)?;
    Ok(format!(
        "ALTER TABLE {} RENAME COLUMN {} TO {}",
        qualified_table(driver_id, schema, table),
        quote_ident(driver_id, old_name),
        quote_ident(driver_id, new_name)
    ))
}

/// Apply column type / nullable / default changes. MySQL's `MODIFY
/// COLUMN` replaces the whole definition, so the caller passes the
/// post-edit `DraftColumn` and this builder emits the full `MODIFY
/// COLUMN col_def`. Postgres / SQLite get one of the per-attribute
/// `ALTER COLUMN ...` sub-statements based on what differs from
/// `column.original` — `_caller_intent` selects which attribute to
/// emit when multiple differ; the caller inspects the diff and calls
/// this once per attribute change for non-MySQL drivers, or once
/// total for MySQL.
pub fn build_alter_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    validate_column_name(&column.name)?;
    let qualified = qualified_table(driver_id, schema, table);
    match driver_id {
        "mysql" => {
            // MySQL's MODIFY COLUMN replaces the whole column
            // definition. Render the column inline (without inline-PK
            // since MODIFY can't change PK) and emit.
            let column_def = render_column_definition(driver_id, column, false)?;
            Ok(format!("ALTER TABLE {} MODIFY COLUMN {}", qualified, column_def))
        }
        "postgres" => {
            // Postgres needs separate sub-statements per attribute.
            // Compute the diff against `original` and pick the most
            // meaningful change. If multiple changed, the caller
            // should call this builder repeatedly via separate ops in
            // the tracker — this single call covers one attribute.
            let original = column.original.as_ref();
            let type_changed = original.map(|o| o.data_type != column.data_type).unwrap_or(true);
            let nullable_changed = original.map(|o| o.nullable != column.nullable).unwrap_or(false);
            let default_changed = original
                .map(|o| o.default_value.as_deref() != column.default_value.as_deref())
                .unwrap_or(column.default_value.is_some());
            if type_changed {
                return Ok(format!(
                    "ALTER TABLE {} ALTER COLUMN {} TYPE {} USING {}::{}",
                    qualified,
                    quote_ident(driver_id, &column.name),
                    column.data_type,
                    quote_ident(driver_id, &column.name),
                    column.data_type,
                ));
            }
            if nullable_changed {
                return Ok(if column.nullable {
                    format!(
                        "ALTER TABLE {} ALTER COLUMN {} DROP NOT NULL",
                        qualified,
                        quote_ident(driver_id, &column.name)
                    )
                } else {
                    format!(
                        "ALTER TABLE {} ALTER COLUMN {} SET NOT NULL",
                        qualified,
                        quote_ident(driver_id, &column.name)
                    )
                });
            }
            if default_changed {
                return Ok(match column.default_value.as_deref().filter(|d| !d.is_empty()) {
                    Some(default) => format!(
                        "ALTER TABLE {} ALTER COLUMN {} SET DEFAULT {}",
                        qualified,
                        quote_ident(driver_id, &column.name),
                        default
                    ),
                    None => format!(
                        "ALTER TABLE {} ALTER COLUMN {} DROP DEFAULT",
                        qualified,
                        quote_ident(driver_id, &column.name)
                    ),
                });
            }
            // Nothing actually changed — caller mistake. Produce a
            // no-op SET TYPE so cargo doesn't have to model the
            // empty-diff case anywhere upstream; the driver will
            // accept it and report 0 affected.
            Ok(format!(
                "ALTER TABLE {} ALTER COLUMN {} TYPE {}",
                qualified,
                quote_ident(driver_id, &column.name),
                column.data_type
            ))
        }
        "sqlite" => Err(BuildDdlError::SqliteNotSupported(
            "ALTER COLUMN (type / nullable / default change)",
        )),
        other => Err(BuildDdlError::UnsupportedDriver(other.to_string())),
    }
}

/// MySQL-only column reorder. Emits `MODIFY COLUMN ... AFTER other`
/// or `MODIFY COLUMN ... FIRST` when `after` is `None`.
pub fn build_reorder_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
    after: Option<&str>,
) -> Result<String, BuildDdlError> {
    validate_table(table)?;
    validate_column_name(&column.name)?;
    if driver_id != "mysql" {
        return Err(BuildDdlError::UnsupportedDriver(driver_id.to_string()));
    }
    let column_def = render_column_definition(driver_id, column, false)?;
    let position = match after {
        Some(name) if !name.is_empty() => format!("AFTER {}", quote_ident(driver_id, name)),
        _ => "FIRST".to_string(),
    };
    Ok(format!(
        "ALTER TABLE {} MODIFY COLUMN {} {}",
        qualified_table(driver_id, schema, table),
        column_def,
        position,
    ))
}

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
    if let Some(action) = fk.on_delete.as_deref().filter(|a| !a.is_empty()) {
        clauses.push(format!("ON DELETE {action}"));
    }
    if let Some(action) = fk.on_update.as_deref().filter(|a| !a.is_empty()) {
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
        "postgres" => Ok(format!(
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

#[cfg(test)]
mod tests {
    use super::*;

    fn dc(name: &str, ty: &str) -> DraftColumn {
        DraftColumn {
            original: None,
            name: name.into(),
            data_type: ty.into(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
        }
    }

    fn pk(mut col: DraftColumn) -> DraftColumn {
        col.primary_key = true;
        col.nullable = false;
        col
    }

    fn ai(mut col: DraftColumn) -> DraftColumn {
        col.auto_increment = true;
        col
    }

    fn nn(mut col: DraftColumn) -> DraftColumn {
        col.nullable = false;
        col
    }

    fn def(mut col: DraftColumn, default: &str) -> DraftColumn {
        col.default_value = Some(default.into());
        col
    }

    #[test]
    fn create_table_simple_postgres() {
        let cols = vec![pk(ai(dc("id", "integer"))), nn(dc("email", "text"))];
        let stmts = build_create_table("postgres", None, "users", &cols, &[], &[]).unwrap();
        assert_eq!(stmts.len(), 1);
        assert!(stmts[0].contains("\"id\" SERIAL PRIMARY KEY"));
        assert!(stmts[0].contains("\"email\" text NOT NULL"));
        assert!(stmts[0].starts_with("CREATE TABLE \"users\""));
    }

    #[test]
    fn create_table_simple_mysql() {
        let cols = vec![pk(ai(dc("id", "INT"))), nn(dc("email", "VARCHAR(255)"))];
        let stmts = build_create_table("mysql", None, "users", &cols, &[], &[]).unwrap();
        assert_eq!(stmts.len(), 1);
        assert!(stmts[0].contains("`id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY"));
        assert!(stmts[0].contains("`email` VARCHAR(255) NOT NULL"));
    }

    #[test]
    fn create_table_simple_sqlite() {
        let cols = vec![pk(ai(dc("id", "INTEGER"))), nn(dc("email", "TEXT"))];
        let stmts = build_create_table("sqlite", None, "users", &cols, &[], &[]).unwrap();
        assert_eq!(stmts.len(), 1);
        assert!(stmts[0].contains("\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL"));
        assert!(stmts[0].contains("\"email\" TEXT NOT NULL"));
    }

    #[test]
    fn create_table_postgres_bigserial() {
        let cols = vec![pk(ai(dc("id", "bigint")))];
        let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
        assert!(stmts[0].contains("BIGSERIAL"));
    }

    #[test]
    fn create_table_composite_pk() {
        let cols = vec![nn(pk(dc("a", "int"))), nn(pk(dc("b", "int"))), dc("c", "text")];
        let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
        // Inline PK only fires for single-column PK — composite emits
        // a separate PRIMARY KEY (a, b) clause at the end.
        assert!(!stmts[0].contains("PRIMARY KEY,"));
        assert!(stmts[0].contains("PRIMARY KEY (\"a\", \"b\")"));
    }

    #[test]
    fn create_table_with_default() {
        let cols = vec![nn(pk(ai(dc("id", "integer")))), def(dc("status", "text"), "'pending'")];
        let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
        assert!(stmts[0].contains("DEFAULT 'pending'"));
    }

    #[test]
    fn create_table_with_schema() {
        let cols = vec![nn(pk(dc("id", "integer")))];
        let stmts = build_create_table("postgres", Some("auth"), "users", &cols, &[], &[]).unwrap();
        assert!(stmts[0].starts_with("CREATE TABLE \"auth\".\"users\""));
    }

    #[test]
    fn create_table_with_secondary_index() {
        let cols = vec![nn(pk(ai(dc("id", "integer")))), nn(dc("email", "text"))];
        let idx = IndexInfo {
            name: "users_email_idx".into(),
            columns: vec!["email".into()],
            unique: true,
            primary: false,
        };
        let stmts = build_create_table("postgres", None, "users", &cols, &[idx], &[]).unwrap();
        assert_eq!(stmts.len(), 2);
        assert!(stmts[1].contains("CREATE UNIQUE INDEX"));
        assert!(stmts[1].contains("\"users_email_idx\""));
    }

    #[test]
    fn create_table_skips_primary_index() {
        let cols = vec![nn(pk(ai(dc("id", "integer"))))];
        let pk_idx = IndexInfo {
            name: "users_pkey".into(),
            columns: vec!["id".into()],
            unique: true,
            primary: true,
        };
        let stmts = build_create_table("postgres", None, "users", &cols, &[pk_idx], &[]).unwrap();
        assert_eq!(stmts.len(), 1, "primary index must not produce a separate CREATE INDEX");
    }

    #[test]
    fn create_table_with_foreign_key() {
        let cols = vec![nn(pk(ai(dc("id", "integer")))), nn(dc("user_id", "integer"))];
        let fk = ForeignKeyInfo {
            name: "fk_user".into(),
            columns: vec!["user_id".into()],
            ref_schema: None,
            ref_table: "users".into(),
            ref_columns: vec!["id".into()],
            on_delete: Some("CASCADE".into()),
            on_update: None,
        };
        let stmts = build_create_table("postgres", None, "orders", &cols, &[], &[fk]).unwrap();
        assert_eq!(stmts.len(), 2);
        assert!(stmts[1].contains("ADD CONSTRAINT \"fk_user\""));
        assert!(stmts[1].contains("ON DELETE CASCADE"));
    }

    #[test]
    fn create_table_sqlite_emits_pragma_for_fk() {
        let cols = vec![nn(pk(dc("id", "INTEGER"))), nn(dc("user_id", "INTEGER"))];
        let fk = ForeignKeyInfo {
            name: "fk_user".into(),
            columns: vec!["user_id".into()],
            ref_schema: None,
            ref_table: "users".into(),
            ref_columns: vec!["id".into()],
            on_delete: None,
            on_update: None,
        };
        let stmts = build_create_table("sqlite", None, "orders", &cols, &[], &[fk]).unwrap();
        assert_eq!(stmts.len(), 3);
        assert_eq!(stmts[1], "PRAGMA foreign_keys = ON");
    }

    #[test]
    fn create_table_rejects_empty_name() {
        let cols = vec![dc("a", "int")];
        let err = build_create_table("postgres", None, "", &cols, &[], &[]).unwrap_err();
        assert!(matches!(err, BuildDdlError::EmptyTableName));
    }

    #[test]
    fn create_table_rejects_no_columns() {
        let err = build_create_table("postgres", None, "t", &[], &[], &[]).unwrap_err();
        assert!(matches!(err, BuildDdlError::NoColumns));
    }

    #[test]
    fn drop_table_basic() {
        assert_eq!(
            build_drop_table("postgres", None, "users", false, false).unwrap(),
            "DROP TABLE \"users\""
        );
        assert_eq!(
            build_drop_table("mysql", None, "users", true, false).unwrap(),
            "DROP TABLE IF EXISTS `users`"
        );
        assert_eq!(
            build_drop_table("postgres", Some("auth"), "users", true, true).unwrap(),
            "DROP TABLE IF EXISTS \"auth\".\"users\" CASCADE"
        );
    }

    #[test]
    fn drop_table_cascade_only_postgres() {
        assert!(
            !build_drop_table("mysql", None, "t", false, true)
                .unwrap()
                .contains("CASCADE")
        );
        assert!(
            !build_drop_table("sqlite", None, "t", false, true)
                .unwrap()
                .contains("CASCADE")
        );
    }

    #[test]
    fn rename_table_each_driver() {
        assert_eq!(
            build_rename_table("postgres", None, "old", "new").unwrap(),
            "ALTER TABLE \"old\" RENAME TO \"new\""
        );
        assert_eq!(
            build_rename_table("mysql", None, "old", "new").unwrap(),
            "ALTER TABLE `old` RENAME TO `new`"
        );
        assert_eq!(
            build_rename_table("sqlite", None, "old", "new").unwrap(),
            "ALTER TABLE \"old\" RENAME TO \"new\""
        );
    }

    #[test]
    fn add_column_basic() {
        let col = nn(def(dc("created_at", "timestamp"), "now()"));
        assert_eq!(
            build_add_column("postgres", None, "users", &col).unwrap(),
            "ALTER TABLE \"users\" ADD COLUMN \"created_at\" timestamp NOT NULL DEFAULT now()"
        );
    }

    #[test]
    fn add_column_sqlite_not_null_without_default_rejected() {
        let col = nn(dc("name", "text"));
        let err = build_add_column("sqlite", None, "t", &col).unwrap_err();
        assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
    }

    #[test]
    fn add_column_sqlite_with_default_ok() {
        let col = nn(def(dc("name", "TEXT"), "''"));
        let sql = build_add_column("sqlite", None, "t", &col).unwrap();
        assert!(sql.starts_with("ALTER TABLE \"t\" ADD COLUMN"));
    }

    #[test]
    fn drop_column_each_driver() {
        assert_eq!(
            build_drop_column("postgres", None, "users", "email").unwrap(),
            "ALTER TABLE \"users\" DROP COLUMN \"email\""
        );
        assert_eq!(
            build_drop_column("mysql", None, "users", "email").unwrap(),
            "ALTER TABLE `users` DROP COLUMN `email`"
        );
        assert_eq!(
            build_drop_column("sqlite", None, "users", "email").unwrap(),
            "ALTER TABLE \"users\" DROP COLUMN \"email\""
        );
    }

    #[test]
    fn rename_column_each_driver() {
        assert_eq!(
            build_rename_column("postgres", None, "t", "old", "new").unwrap(),
            "ALTER TABLE \"t\" RENAME COLUMN \"old\" TO \"new\""
        );
        assert_eq!(
            build_rename_column("mysql", None, "t", "old", "new").unwrap(),
            "ALTER TABLE `t` RENAME COLUMN `old` TO `new`"
        );
    }

    #[test]
    fn alter_column_postgres_type_change() {
        let col = DraftColumn {
            original: Some(ColumnInfo {
                name: "x".into(),
                data_type: "integer".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
            }),
            name: "x".into(),
            data_type: "bigint".into(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
        };
        let sql = build_alter_column("postgres", None, "t", &col).unwrap();
        assert!(sql.contains("TYPE bigint"));
        assert!(sql.contains("USING \"x\"::bigint"));
    }

    #[test]
    fn alter_column_postgres_nullable_change() {
        let col = DraftColumn {
            original: Some(ColumnInfo {
                name: "x".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
            }),
            name: "x".into(),
            data_type: "text".into(),
            nullable: false,
            primary_key: false,
            auto_increment: false,
            default_value: None,
        };
        let sql = build_alter_column("postgres", None, "t", &col).unwrap();
        assert!(sql.contains("SET NOT NULL"));
    }

    #[test]
    fn alter_column_postgres_default_change() {
        let col = DraftColumn {
            original: Some(ColumnInfo {
                name: "x".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
            }),
            name: "x".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: Some("'pending'".into()),
        };
        let sql = build_alter_column("postgres", None, "t", &col).unwrap();
        assert!(sql.contains("SET DEFAULT 'pending'"));
    }

    #[test]
    fn alter_column_mysql_modify_full_def() {
        let col = nn(def(dc("status", "VARCHAR(64)"), "'open'"));
        let sql = build_alter_column("mysql", None, "t", &col).unwrap();
        assert_eq!(
            sql,
            "ALTER TABLE `t` MODIFY COLUMN `status` VARCHAR(64) NOT NULL DEFAULT 'open'"
        );
    }

    #[test]
    fn alter_column_sqlite_rejected() {
        let col = dc("x", "TEXT");
        let err = build_alter_column("sqlite", None, "t", &col).unwrap_err();
        assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
    }

    #[test]
    fn reorder_column_mysql() {
        let col = nn(dc("status", "VARCHAR(64)"));
        let sql = build_reorder_column("mysql", None, "t", &col, Some("name")).unwrap();
        assert_eq!(
            sql,
            "ALTER TABLE `t` MODIFY COLUMN `status` VARCHAR(64) NOT NULL AFTER `name`"
        );
    }

    #[test]
    fn reorder_column_mysql_first() {
        let col = nn(dc("id", "INT"));
        let sql = build_reorder_column("mysql", None, "t", &col, None).unwrap();
        assert!(sql.ends_with("FIRST"));
    }

    #[test]
    fn reorder_column_postgres_rejected() {
        let col = dc("x", "text");
        let err = build_reorder_column("postgres", None, "t", &col, Some("y")).unwrap_err();
        assert!(matches!(err, BuildDdlError::UnsupportedDriver(_)));
    }

    #[test]
    fn reorder_column_sqlite_rejected() {
        let col = dc("x", "TEXT");
        let err = build_reorder_column("sqlite", None, "t", &col, None).unwrap_err();
        assert!(matches!(err, BuildDdlError::UnsupportedDriver(_)));
    }

    #[test]
    fn create_index_basic() {
        let idx = IndexInfo {
            name: "users_email_idx".into(),
            columns: vec!["email".into()],
            unique: true,
            primary: false,
        };
        assert_eq!(
            build_create_index("postgres", None, "users", &idx).unwrap(),
            "CREATE UNIQUE INDEX \"users_email_idx\" ON \"users\" (\"email\")"
        );
    }

    #[test]
    fn create_index_compound_columns() {
        let idx = IndexInfo {
            name: "idx_a_b".into(),
            columns: vec!["a".into(), "b".into()],
            unique: false,
            primary: false,
        };
        let sql = build_create_index("mysql", None, "t", &idx).unwrap();
        assert_eq!(sql, "CREATE INDEX `idx_a_b` ON `t` (`a`, `b`)");
    }

    #[test]
    fn create_index_rejects_empty_name() {
        let idx = IndexInfo {
            name: "".into(),
            columns: vec!["x".into()],
            unique: false,
            primary: false,
        };
        let err = build_create_index("postgres", None, "t", &idx).unwrap_err();
        assert!(matches!(err, BuildDdlError::EmptyIndexName));
    }

    #[test]
    fn drop_index_postgres() {
        assert_eq!(
            build_drop_index("postgres", Some("public"), "t", "my_idx").unwrap(),
            "DROP INDEX IF EXISTS \"public\".\"my_idx\""
        );
    }

    #[test]
    fn drop_index_mysql_uses_alter_table() {
        assert_eq!(
            build_drop_index("mysql", None, "t", "my_idx").unwrap(),
            "ALTER TABLE `t` DROP INDEX `my_idx`"
        );
    }

    #[test]
    fn drop_index_sqlite() {
        assert_eq!(
            build_drop_index("sqlite", None, "t", "my_idx").unwrap(),
            "DROP INDEX IF EXISTS \"my_idx\""
        );
    }

    fn fk_basic() -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: "fk_user".into(),
            columns: vec!["user_id".into()],
            ref_schema: None,
            ref_table: "users".into(),
            ref_columns: vec!["id".into()],
            on_delete: Some("CASCADE".into()),
            on_update: Some("RESTRICT".into()),
        }
    }

    #[test]
    fn add_foreign_key_postgres() {
        let sql = build_add_foreign_key("postgres", None, "orders", &fk_basic()).unwrap();
        assert!(sql.contains("ADD CONSTRAINT \"fk_user\""));
        assert!(sql.contains("FOREIGN KEY (\"user_id\")"));
        assert!(sql.contains("REFERENCES \"users\" (\"id\")"));
        assert!(sql.contains("ON DELETE CASCADE"));
        assert!(sql.contains("ON UPDATE RESTRICT"));
    }

    #[test]
    fn add_foreign_key_mysql_backticks() {
        let sql = build_add_foreign_key("mysql", None, "orders", &fk_basic()).unwrap();
        assert!(sql.contains("`fk_user`"));
        assert!(sql.contains("`user_id`"));
    }

    #[test]
    fn add_foreign_key_omits_actions_when_none() {
        let mut fk = fk_basic();
        fk.on_delete = None;
        fk.on_update = None;
        let sql = build_add_foreign_key("postgres", None, "orders", &fk).unwrap();
        assert!(!sql.contains("ON DELETE"));
        assert!(!sql.contains("ON UPDATE"));
    }

    #[test]
    fn drop_foreign_key_postgres() {
        assert_eq!(
            build_drop_foreign_key("postgres", None, "orders", "fk_user").unwrap(),
            "ALTER TABLE \"orders\" DROP CONSTRAINT \"fk_user\""
        );
    }

    #[test]
    fn drop_foreign_key_mysql() {
        assert_eq!(
            build_drop_foreign_key("mysql", None, "orders", "fk_user").unwrap(),
            "ALTER TABLE `orders` DROP FOREIGN KEY `fk_user`"
        );
    }

    #[test]
    fn drop_foreign_key_sqlite_rejected() {
        let err = build_drop_foreign_key("sqlite", None, "orders", "fk_user").unwrap_err();
        assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
    }

    #[test]
    fn quoted_identifiers_round_trip_through_qualified_table() {
        // Schema + table with embedded quote chars: identifier quoting
        // must double the inner quote.
        let sql = build_drop_table("postgres", Some("a\"b"), "c\"d", false, false).unwrap();
        assert!(sql.contains("\"a\"\"b\".\"c\"\"d\""));
    }
}
