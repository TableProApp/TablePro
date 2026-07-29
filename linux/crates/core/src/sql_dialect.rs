use thiserror::Error;

use crate::{ColumnInfo, Value};

#[derive(Debug, Error)]
pub enum BuildSqlError {
    #[error("table has no primary key")]
    NoPrimaryKey,

    #[error("nothing to update")]
    NothingToUpdate,

    #[error("new_values length {got} does not match columns length {expected}")]
    LengthMismatch { expected: usize, got: usize },
}

pub fn quote_ident(driver_id: &str, name: &str) -> String {
    match driver_id {
        "mysql" | "clickhouse" => format!("`{}`", name.replace('`', "``")),
        "mssql" => format!("[{}]", name.replace(']', "]]")),
        _ => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

pub fn placeholder_for(driver_id: &str, index: usize) -> String {
    match driver_id {
        "postgres" => format!("${}", index + 1),
        "mssql" => format!("@P{}", index + 1),
        _ => "?".to_string(),
    }
}

/// Render an `UPDATE`. ClickHouse only accepted standard `UPDATE`
/// syntax from 25.7; the spelling that works across every supported
/// release is `ALTER TABLE … UPDATE`, which the server applies as a
/// mutation. `qualified_table`, `set_clause` and `where_clause` are
/// pre-built SQL, not identifiers.
pub fn build_update(driver_id: &str, qualified_table: &str, set_clause: &str, where_clause: &str) -> String {
    match driver_id {
        "clickhouse" => format!("ALTER TABLE {qualified_table} UPDATE {set_clause} WHERE {where_clause}"),
        _ => format!("UPDATE {qualified_table} SET {set_clause} WHERE {where_clause}"),
    }
}

/// Render the `ORDER BY` and row-window tail of a paged `SELECT`,
/// including the leading space. The two clauses are built together
/// because SQL Server couples them: `OFFSET … FETCH` is defined as a
/// suffix of `ORDER BY`, so a paged query with no user sort still
/// needs one. `(SELECT NULL)` is the no-op ordering that satisfies the
/// parser without imposing a sort the user did not ask for.
///
/// `order_by` is pre-quoted SQL (`"name" ASC, "id" DESC`), not an
/// identifier.
pub fn build_order_and_pagination(driver_id: &str, order_by: Option<&str>, limit: u64, offset: u64) -> String {
    let order_by = order_by.map(str::trim).filter(|o| !o.is_empty());
    if driver_id == "mssql" {
        let order = order_by.unwrap_or("(SELECT NULL)");
        return format!(" ORDER BY {order} OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY");
    }
    match order_by {
        Some(order) => format!(" ORDER BY {order} LIMIT {limit} OFFSET {offset}"),
        None => format!(" LIMIT {limit} OFFSET {offset}"),
    }
}

pub fn build_single_cell_update(
    driver_id: &str,
    table: &str,
    columns: &[ColumnInfo],
    original_row: &[Value],
    col_index: usize,
    new_value: Value,
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = collect_pk_indexes(columns);
    if pk_indexes.is_empty() {
        return Err(BuildSqlError::NoPrimaryKey);
    }
    if original_row.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: original_row.len(),
        });
    }

    let mut params: Vec<Value> = Vec::with_capacity(1 + pk_indexes.len());
    let mut placeholder_idx = 0;

    let set_clause = format!(
        "{} = {}",
        quote_ident(driver_id, &columns[col_index].name),
        placeholder_for(driver_id, placeholder_idx)
    );
    placeholder_idx += 1;
    params.push(new_value);

    let where_clause = build_where_clause(
        driver_id,
        columns,
        &pk_indexes,
        original_row,
        &mut placeholder_idx,
        &mut params,
    );

    let sql = build_update(driver_id, &quote_ident(driver_id, table), &set_clause, &where_clause);
    Ok((sql, params))
}

pub fn build_full_row_update(
    driver_id: &str,
    table: &str,
    columns: &[ColumnInfo],
    original_row: &[Value],
    new_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = collect_pk_indexes(columns);
    if pk_indexes.is_empty() {
        return Err(BuildSqlError::NoPrimaryKey);
    }
    if new_values.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: new_values.len(),
        });
    }
    if original_row.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: original_row.len(),
        });
    }

    let mut params: Vec<Value> = Vec::new();
    let mut placeholder_idx = 0;

    let mut set_clauses = Vec::new();
    for (i, col) in columns.iter().enumerate() {
        if col.primary_key {
            continue;
        }
        set_clauses.push(format!(
            "{} = {}",
            quote_ident(driver_id, &col.name),
            placeholder_for(driver_id, placeholder_idx)
        ));
        placeholder_idx += 1;
        params.push(new_values[i].clone());
    }
    if set_clauses.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }

    let where_clause = build_where_clause(
        driver_id,
        columns,
        &pk_indexes,
        original_row,
        &mut placeholder_idx,
        &mut params,
    );

    let sql = build_update(
        driver_id,
        &quote_ident(driver_id, table),
        &set_clauses.join(", "),
        &where_clause,
    );
    Ok((sql, params))
}

/// Build an INSERT for a draft row collected by the inline-edit
/// changeset. Skips auto-increment columns and generated columns
/// entirely (the database supplies their values). For nullable
/// columns whose `Value` is `Null` AND have a `default_value`,
/// also skip the column so the server applies its default rather
/// than receiving an explicit NULL.
pub fn build_insert_from_draft(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    values: &[Value],
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
        if col.is_auto_increment || col.is_generated {
            continue;
        }
        let value_is_null = matches!(values[i], Value::Null);
        if value_is_null && col.default_value.is_some() {
            // Let the server apply its default rather than overriding
            // it with an explicit NULL — matters when the default is
            // CURRENT_TIMESTAMP, gen_random_uuid(), etc.
            continue;
        }
        col_idents.push(quote_ident(driver_id, &col.name));
        placeholders.push(placeholder_for(driver_id, params.len()));
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

fn collect_pk_indexes(columns: &[ColumnInfo]) -> Vec<usize> {
    columns
        .iter()
        .enumerate()
        .filter(|(_, c)| c.primary_key)
        .map(|(i, _)| i)
        .collect()
}

fn build_where_clause(
    driver_id: &str,
    columns: &[ColumnInfo],
    pk_indexes: &[usize],
    original_row: &[Value],
    placeholder_idx: &mut usize,
    params: &mut Vec<Value>,
) -> String {
    let mut clauses = Vec::with_capacity(pk_indexes.len());
    for pk_col in pk_indexes {
        let ident = quote_ident(driver_id, &columns[*pk_col].name);
        // SQL three-valued logic: `col = NULL` is never true. A nullable
        // PK component holding NULL must use `IS NULL` or the UPDATE /
        // DELETE silently matches zero rows.
        if matches!(original_row[*pk_col], Value::Null) {
            clauses.push(format!("{ident} IS NULL"));
        } else {
            clauses.push(format!("{ident} = {}", placeholder_for(driver_id, *placeholder_idx)));
            *placeholder_idx += 1;
            params.push(original_row[*pk_col].clone());
        }
    }
    clauses.join(" AND ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(name: &str, pk: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: false,
            primary_key: pk,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        }
    }

    #[test]
    fn quote_ident_dialect() {
        assert_eq!(quote_ident("postgres", "users"), "\"users\"");
        assert_eq!(quote_ident("sqlite", "users"), "\"users\"");
        assert_eq!(quote_ident("mysql", "users"), "`users`");
        assert_eq!(quote_ident("clickhouse", "users"), "`users`");
        assert_eq!(quote_ident("clickhouse", "a`b"), "`a``b`");
    }

    #[test]
    fn quote_ident_doubles_embedded_delimiter() {
        assert_eq!(quote_ident("postgres", "foo\"bar"), "\"foo\"\"bar\"");
        assert_eq!(quote_ident("mysql", "foo`bar"), "`foo``bar`");
    }

    #[test]
    fn quote_ident_mssql() {
        assert_eq!(quote_ident("mssql", "users"), "[users]");
        assert_eq!(quote_ident("mssql", "a]b"), "[a]]b]");
    }

    #[test]
    fn placeholder_dialect() {
        assert_eq!(placeholder_for("postgres", 0), "$1");
        assert_eq!(placeholder_for("postgres", 2), "$3");
        assert_eq!(placeholder_for("sqlite", 0), "?");
        assert_eq!(placeholder_for("mysql", 5), "?");
    }

    #[test]
    fn placeholder_mssql() {
        assert_eq!(placeholder_for("mssql", 0), "@P1");
        assert_eq!(placeholder_for("mssql", 2), "@P3");
    }

    #[test]
    fn pagination_limit_offset_dialects() {
        assert_eq!(
            build_order_and_pagination("postgres", None, 50, 100),
            " LIMIT 50 OFFSET 100"
        );
        assert_eq!(
            build_order_and_pagination("mysql", Some("`a` ASC"), 50, 100),
            " ORDER BY `a` ASC LIMIT 50 OFFSET 100"
        );
        assert_eq!(
            build_order_and_pagination("sqlite", Some("\"a\" DESC"), 10, 0),
            " ORDER BY \"a\" DESC LIMIT 10 OFFSET 0"
        );
    }

    #[test]
    fn pagination_mssql_uses_offset_fetch() {
        assert_eq!(
            build_order_and_pagination("mssql", Some("[a] ASC"), 50, 100),
            " ORDER BY [a] ASC OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY"
        );
    }

    #[test]
    fn pagination_mssql_synthesizes_order_by_when_unsorted() {
        // OFFSET / FETCH is a suffix of ORDER BY in T-SQL, so an
        // unsorted page still needs one to parse at all.
        let sql = build_order_and_pagination("mssql", None, 50, 0);
        assert_eq!(sql, " ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY");
    }

    #[test]
    fn pagination_treats_blank_order_by_as_absent() {
        assert_eq!(
            build_order_and_pagination("postgres", Some("  "), 5, 0),
            " LIMIT 5 OFFSET 0"
        );
        assert_eq!(
            build_order_and_pagination("mssql", Some("  "), 5, 0),
            " ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY"
        );
    }

    #[test]
    fn single_cell_update_postgres() {
        let columns = vec![col("id", true), col("name", false)];
        let original = vec![Value::Int(7), Value::Text("alice".into())];
        let (sql, params) =
            build_single_cell_update("postgres", "u", &columns, &original, 1, Value::Text("bob".into())).unwrap();
        assert_eq!(sql, "UPDATE \"u\" SET \"name\" = $1 WHERE \"id\" = $2");
        assert_eq!(params, vec![Value::Text("bob".into()), Value::Int(7)]);
    }

    #[test]
    fn single_cell_update_mysql() {
        let columns = vec![col("id", true), col("name", false)];
        let original = vec![Value::Int(7), Value::Text("alice".into())];
        let (sql, params) =
            build_single_cell_update("mysql", "u", &columns, &original, 1, Value::Text("bob".into())).unwrap();
        assert_eq!(sql, "UPDATE `u` SET `name` = ? WHERE `id` = ?");
        assert_eq!(params, vec![Value::Text("bob".into()), Value::Int(7)]);
    }

    #[test]
    fn single_cell_update_clickhouse() {
        let columns = vec![col("id", true), col("name", false)];
        let original = vec![Value::Int(7), Value::Text("alice".into())];
        let (sql, params) =
            build_single_cell_update("clickhouse", "u", &columns, &original, 1, Value::Text("bob".into())).unwrap();
        assert_eq!(sql, "ALTER TABLE `u` UPDATE `name` = ? WHERE `id` = ?");
        assert_eq!(params, vec![Value::Text("bob".into()), Value::Int(7)]);
    }

    #[test]
    fn full_row_update_clickhouse() {
        let columns = vec![col("id", true), col("a", false), col("b", false)];
        let original = vec![Value::Int(1), Value::Text("x".into()), Value::Text("y".into())];
        let new_values = vec![Value::Int(1), Value::Text("x2".into()), Value::Text("y2".into())];
        let (sql, _) = build_full_row_update("clickhouse", "t", &columns, &original, &new_values).unwrap();
        assert_eq!(sql, "ALTER TABLE `t` UPDATE `a` = ?, `b` = ? WHERE `id` = ?");
    }

    #[test]
    fn build_update_keeps_standard_syntax_for_other_dialects() {
        assert_eq!(
            build_update("postgres", "\"t\"", "\"a\" = $1", "\"id\" = $2"),
            "UPDATE \"t\" SET \"a\" = $1 WHERE \"id\" = $2"
        );
        assert_eq!(
            build_update("clickhouse", "`t`", "`a` = ?", "`id` = ?"),
            "ALTER TABLE `t` UPDATE `a` = ? WHERE `id` = ?"
        );
    }

    #[test]
    fn single_cell_update_sqlite() {
        let columns = vec![col("id", true), col("v", false)];
        let original = vec![Value::Int(1), Value::Text("a".into())];
        let (sql, _) =
            build_single_cell_update("sqlite", "t", &columns, &original, 1, Value::Text("b".into())).unwrap();
        assert_eq!(sql, "UPDATE \"t\" SET \"v\" = ? WHERE \"id\" = ?");
    }

    #[test]
    fn single_cell_update_mssql() {
        let columns = vec![col("id", true), col("name", false)];
        let original = vec![Value::Int(7), Value::Text("alice".into())];
        let (sql, params) =
            build_single_cell_update("mssql", "u", &columns, &original, 1, Value::Text("bob".into())).unwrap();
        assert_eq!(sql, "UPDATE [u] SET [name] = @P1 WHERE [id] = @P2");
        assert_eq!(params, vec![Value::Text("bob".into()), Value::Int(7)]);
    }

    #[test]
    fn single_cell_update_no_pk() {
        let columns = vec![col("a", false), col("b", false)];
        let original = vec![Value::Int(1), Value::Int(2)];
        let err = build_single_cell_update("sqlite", "t", &columns, &original, 0, Value::Int(9)).unwrap_err();
        assert!(matches!(err, BuildSqlError::NoPrimaryKey));
    }

    #[test]
    fn single_cell_update_composite_pk() {
        let columns = vec![col("a", true), col("b", true), col("c", false)];
        let original = vec![Value::Int(1), Value::Int(2), Value::Text("x".into())];
        let (sql, params) =
            build_single_cell_update("postgres", "t", &columns, &original, 2, Value::Text("y".into())).unwrap();
        assert_eq!(sql, "UPDATE \"t\" SET \"c\" = $1 WHERE \"a\" = $2 AND \"b\" = $3");
        assert_eq!(params.len(), 3);
    }

    #[test]
    fn full_row_update_skips_pk() {
        let columns = vec![col("id", true), col("name", false), col("age", false)];
        let original = vec![Value::Int(3), Value::Text("a".into()), Value::Int(20)];
        let new_values = vec![Value::Int(3), Value::Text("b".into()), Value::Int(21)];
        let (sql, params) = build_full_row_update("mysql", "p", &columns, &original, &new_values).unwrap();
        assert_eq!(sql, "UPDATE `p` SET `name` = ?, `age` = ? WHERE `id` = ?");
        assert_eq!(params.len(), 3);
        assert_eq!(params[2], Value::Int(3));
    }

    #[test]
    fn full_row_update_length_mismatch() {
        let columns = vec![col("id", true), col("v", false)];
        let original = vec![Value::Int(1), Value::Int(2)];
        let new_values = vec![Value::Int(1)];
        let err = build_full_row_update("postgres", "t", &columns, &original, &new_values).unwrap_err();
        assert!(matches!(err, BuildSqlError::LengthMismatch { expected: 2, got: 1 }));
    }

    fn col_auto(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: true,
            default_value: None,
            is_generated: false,
        }
    }

    fn col_with_default(name: &str, default: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "timestamp".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: Some(default.into()),
            is_generated: false,
        }
    }

    fn col_generated(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: true,
        }
    }

    #[test]
    fn insert_from_draft_skips_auto_increment_pk() {
        let columns = vec![col_auto("id"), col("name", false)];
        let values = vec![Value::Null, Value::Text("alice".into())];
        let (sql, params) = build_insert_from_draft("postgres", None, "users", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO \"users\" (\"name\") VALUES ($1)");
        assert_eq!(params, vec![Value::Text("alice".into())]);
    }

    #[test]
    fn insert_from_draft_skips_generated_columns() {
        let columns = vec![col("a", false), col_generated("total"), col("b", false)];
        let values = vec![Value::Int(1), Value::Int(99), Value::Int(2)];
        let (sql, params) = build_insert_from_draft("mysql", None, "t", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO `t` (`a`, `b`) VALUES (?, ?)");
        assert_eq!(params, vec![Value::Int(1), Value::Int(2)]);
    }

    #[test]
    fn insert_from_draft_mssql() {
        let columns = vec![col_auto("id"), col("name", false)];
        let values = vec![Value::Null, Value::Text("alice".into())];
        let (sql, params) = build_insert_from_draft("mssql", None, "users", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO [users] ([name]) VALUES (@P1)");
        assert_eq!(params, vec![Value::Text("alice".into())]);
    }

    #[test]
    fn insert_from_draft_omits_null_when_default_exists() {
        // Cell is NULL and column has a server default (e.g., now()) →
        // omit the column from INSERT so the server applies its default.
        let columns = vec![col("name", false), col_with_default("created_at", "now()")];
        let values = vec![Value::Text("bob".into()), Value::Null];
        let (sql, _) = build_insert_from_draft("postgres", None, "u", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO \"u\" (\"name\") VALUES ($1)");
    }

    #[test]
    fn insert_from_draft_keeps_explicit_null_without_default() {
        let columns = vec![col("name", false), col("nickname", false)];
        let values = vec![Value::Text("bob".into()), Value::Null];
        let (sql, params) = build_insert_from_draft("postgres", None, "u", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO \"u\" (\"name\", \"nickname\") VALUES ($1, $2)");
        assert_eq!(params, vec![Value::Text("bob".into()), Value::Null]);
    }

    #[test]
    fn insert_from_draft_qualifies_with_schema() {
        let columns = vec![col("id", true), col("name", false)];
        let values = vec![Value::Int(1), Value::Text("a".into())];
        let (sql, _) = build_insert_from_draft("postgres", Some("public"), "u", &columns, &values).unwrap();
        assert_eq!(sql, "INSERT INTO \"public\".\"u\" (\"id\", \"name\") VALUES ($1, $2)");
    }

    #[test]
    fn where_clause_uses_is_null_for_null_pk_components() {
        let columns = vec![col("a", true), col("b", true), col("c", false)];
        let original = vec![Value::Int(1), Value::Null, Value::Text("x".into())];
        let (sql, params) =
            build_single_cell_update("postgres", "t", &columns, &original, 2, Value::Text("y".into())).unwrap();
        assert_eq!(sql, "UPDATE \"t\" SET \"c\" = $1 WHERE \"a\" = $2 AND \"b\" IS NULL");
        // params: new_value, plus the non-null PK component only — the NULL
        // PK component does not consume a placeholder.
        assert_eq!(params, vec![Value::Text("y".into()), Value::Int(1)]);
    }

    #[test]
    fn where_clause_all_null_pk_no_placeholders() {
        let columns = vec![col("a", true), col("b", true), col("c", false)];
        let original = vec![Value::Null, Value::Null, Value::Text("x".into())];
        let (sql, params) =
            build_single_cell_update("mysql", "t", &columns, &original, 2, Value::Text("y".into())).unwrap();
        assert_eq!(sql, "UPDATE `t` SET `c` = ? WHERE `a` IS NULL AND `b` IS NULL");
        assert_eq!(params, vec![Value::Text("y".into())]);
    }

    #[test]
    fn insert_from_draft_returns_error_when_only_auto_columns() {
        let columns = vec![col_auto("id"), col_generated("calc")];
        let values = vec![Value::Null, Value::Null];
        let err = build_insert_from_draft("postgres", None, "t", &columns, &values).unwrap_err();
        assert!(matches!(err, BuildSqlError::NothingToUpdate));
    }
}
