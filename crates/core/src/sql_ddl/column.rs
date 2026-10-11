use crate::sql_dialect::quote_ident;

use super::types::{
    BuildDdlError, DraftColumn, collation_clause, column_comment_statement, comment_changed,
    mssql_drop_default_constraint, qualified_table, render_column_definition, sql_literal, validate_column_name,
    validate_safe_type, validate_table, validated_default,
};

/// Add a column. Returns more than one statement on a dialect that
/// keeps a column comment outside the column definition.
pub fn build_add_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<Vec<String>, BuildDdlError> {
    validate_table(table)?;
    let column_def = render_column_definition(driver_id, column, false)?;
    if driver_id == "sqlite" && !column.nullable && column.default_value.as_deref().unwrap_or("").is_empty() {
        // SQLite refuses ADD COLUMN NOT NULL unless the column has a
        // DEFAULT (or is a generated column we don't yet handle).
        // Surface the limit at build time so the UI can show a clear
        // error before sending the statement to the driver.
        return Err(BuildDdlError::SqliteNotSupported("ADD COLUMN NOT NULL without DEFAULT"));
    }
    let keyword = if driver_id == "mssql" { "ADD" } else { "ADD COLUMN" };
    let mut stmts = vec![format!(
        "ALTER TABLE {} {} {}",
        qualified_table(driver_id, schema, table),
        keyword,
        column_def
    )];
    if column.comment.is_some()
        && let Some(comment_stmt) = column_comment_statement(driver_id, schema, table, column)?
    {
        stmts.push(comment_stmt);
    }
    Ok(stmts)
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
    if driver_id == "mssql" {
        // Same string-literal escaping requirement as build_rename_table.
        let object_name = sql_literal(&format!(
            "{}.{}",
            qualified_table(driver_id, schema, table),
            quote_ident(driver_id, old_name)
        ));
        let new_bare = sql_literal(new_name.trim());
        return Ok(format!("EXEC sp_rename '{}', '{}', 'COLUMN'", object_name, new_bare));
    }
    Ok(format!(
        "ALTER TABLE {} RENAME COLUMN {} TO {}",
        qualified_table(driver_id, schema, table),
        quote_ident(driver_id, old_name),
        quote_ident(driver_id, new_name)
    ))
}

/// Apply column type / nullable / default changes. Returns one or
/// more SQL statements:
///
/// - **MySQL**: a single `ALTER TABLE ... MODIFY COLUMN col_def` that
///   replaces the whole definition.
/// - **Postgres**: one `ALTER TABLE ... ALTER COLUMN ...` per
///   attribute that diffed against `column.original`.
/// - **SQLite**: not supported; returns `SqliteNotSupported`.
pub fn build_alter_column(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<Vec<String>, BuildDdlError> {
    validate_table(table)?;
    validate_column_name(&column.name)?;
    match driver_id {
        "mysql" => alter_column_mysql(driver_id, schema, table, column),
        "postgres" => alter_column_postgres(driver_id, schema, table, column),
        "mssql" => alter_column_mssql(driver_id, schema, table, column),
        "sqlite" => Err(BuildDdlError::SqliteNotSupported(
            "ALTER COLUMN (type / nullable / default change)",
        )),
        other => Err(BuildDdlError::UnsupportedDriver(other.to_string())),
    }
}

struct ChangedAttributes {
    data_type: bool,
    nullable: bool,
    default_value: bool,
}

impl ChangedAttributes {
    fn of(column: &DraftColumn) -> Self {
        let original = column.original.as_ref();
        Self {
            data_type: original.map(|o| o.data_type != column.data_type).unwrap_or(true),
            nullable: original.map(|o| o.nullable != column.nullable).unwrap_or(false),
            default_value: original
                .map(|o| o.default_value.as_deref() != column.default_value.as_deref())
                .unwrap_or(column.default_value.is_some()),
        }
    }
}

/// MySQL's MODIFY COLUMN replaces the whole column definition, so one
/// statement carries every changed attribute. Inline PK is left out
/// because MODIFY cannot change the primary key.
fn alter_column_mysql(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<Vec<String>, BuildDdlError> {
    let column_def = render_column_definition(driver_id, column, false)?;
    Ok(vec![format!(
        "ALTER TABLE {} MODIFY COLUMN {}",
        qualified_table(driver_id, schema, table),
        column_def
    )])
}

/// Postgres needs one sub-statement per changed attribute. Emitting
/// only the first changed one silently loses the user's other edits,
/// so every changed attribute gets its own statement.
fn alter_column_postgres(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<Vec<String>, BuildDdlError> {
    let qualified = qualified_table(driver_id, schema, table);
    let name = quote_ident(driver_id, &column.name);
    let changed = ChangedAttributes::of(column);
    let mut stmts: Vec<String> = Vec::new();
    if changed.data_type {
        validate_safe_type(&column.data_type)?;
        let collation = collation_clause(driver_id, column)?
            .map(|clause| format!(" {clause}"))
            .unwrap_or_default();
        stmts.push(format!(
            "ALTER TABLE {} ALTER COLUMN {} TYPE {}{} USING {}::{}",
            qualified, name, column.data_type, collation, name, column.data_type,
        ));
    }
    if changed.nullable {
        let action = if column.nullable {
            "DROP NOT NULL"
        } else {
            "SET NOT NULL"
        };
        stmts.push(format!("ALTER TABLE {} ALTER COLUMN {} {}", qualified, name, action));
    }
    if changed.default_value {
        stmts.push(match validated_default(column.default_value.as_deref())? {
            Some(default) => format!(
                "ALTER TABLE {} ALTER COLUMN {} SET DEFAULT {}",
                qualified, name, default
            ),
            None => format!("ALTER TABLE {} ALTER COLUMN {} DROP DEFAULT", qualified, name),
        });
    }
    if comment_changed(column)
        && let Some(comment_stmt) = column_comment_statement(driver_id, schema, table, column)?
    {
        stmts.push(comment_stmt);
    }
    if stmts.is_empty() {
        return Err(BuildDdlError::NoChange);
    }
    Ok(stmts)
}

fn alter_column_mssql(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    column: &DraftColumn,
) -> Result<Vec<String>, BuildDdlError> {
    let qualified = qualified_table(driver_id, schema, table);
    let name = quote_ident(driver_id, &column.name);
    let changed = ChangedAttributes::of(column);
    let mut stmts: Vec<String> = Vec::new();
    // ALTER COLUMN carries type and nullability together: T-SQL
    // reads an omitted NULL / NOT NULL as NULL, so a type-only
    // change has to restate the nullability or it would silently
    // drop NOT NULL.
    if changed.data_type || changed.nullable {
        validate_safe_type(&column.data_type)?;
        let nullability = if column.nullable { "NULL" } else { "NOT NULL" };
        let collation = collation_clause(driver_id, column)?
            .map(|clause| format!(" {clause}"))
            .unwrap_or_default();
        stmts.push(format!(
            "ALTER TABLE {} ALTER COLUMN {} {}{} {}",
            qualified, name, column.data_type, collation, nullability
        ));
    }
    if changed.default_value {
        // A default is a separate named constraint here, not a
        // column attribute, so changing one is drop-then-add. The
        // existing constraint's name is generated by the server, so
        // the drop resolves it from the catalog.
        stmts.push(mssql_drop_default_constraint(driver_id, schema, table, &column.name));
        if let Some(default) = validated_default(column.default_value.as_deref())? {
            stmts.push(format!(
                "ALTER TABLE {} ADD DEFAULT ({}) FOR {}",
                qualified, default, name
            ));
        }
    }
    if comment_changed(column)
        && let Some(comment_stmt) = column_comment_statement(driver_id, schema, table, column)?
    {
        stmts.push(comment_stmt);
    }
    if stmts.is_empty() {
        return Err(BuildDdlError::NoChange);
    }
    Ok(stmts)
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
