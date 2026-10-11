use thiserror::Error;

use crate::{ColumnInfo, Value};

#[cfg(test)]
#[path = "sql_dialect/postgres_enum_tests.rs"]
mod postgres_enum_tests;

mod error;
#[path = "sql_dialect/updates.rs"]
mod updates;

pub use error::BuildSqlError;
pub use updates::{
    build_keyed_update, build_keyed_value_select, build_mongodb_keyed_delete, build_mongodb_keyed_update,
    build_optimistic_keyed_update,
};

pub const MAX_IDENT_BYTES: usize = 256;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum IdentError {
    #[error("identifier is empty")]
    Empty,

    #[error("identifier is longer than {MAX_IDENT_BYTES} bytes")]
    TooLong,

    #[error("identifier contains a control character")]
    ControlCharacter,
}

pub fn validate_ident(name: &str) -> Result<(), IdentError> {
    if name.trim().is_empty() {
        return Err(IdentError::Empty);
    }
    if name.len() > MAX_IDENT_BYTES {
        return Err(IdentError::TooLong);
    }
    if name
        .chars()
        .any(|character| character.is_control() || character == '\u{2028}' || character == '\u{2029}')
    {
        return Err(IdentError::ControlCharacter);
    }
    Ok(())
}

pub fn quote_ident(driver_id: &str, name: &str) -> String {
    let name: std::borrow::Cow<'_, str> = if validate_ident(name).is_err() {
        name.chars().filter(|c| !c.is_control()).collect::<String>().into()
    } else {
        name.into()
    };
    match driver_id {
        // ClickHouse backtick-quoted identifiers treat a backslash as an
        // escape character, exactly like its string literals (sql_literal.rs);
        // a table named `evil\` would otherwise consume the closing backtick.
        "clickhouse" => format!("`{}`", name.replace('\\', "\\\\").replace('`', "``")),
        "mysql" => format!("`{}`", name.replace('`', "``")),
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

fn postgres_text_cast_type(column: &ColumnInfo, value: &Value) -> Option<String> {
    if let Some(domain_type) = &column.domain_type
        && matches!(value, Value::Text(_) | Value::Null)
    {
        return Some(format!(
            "{}.{}",
            quote_ident("postgres", &domain_type.schema),
            quote_ident("postgres", &domain_type.name)
        ));
    }
    if let Some(enum_type) = &column.enum_type
        && matches!(value, Value::Text(_) | Value::Null)
    {
        let array_suffix = if column.data_type.trim().ends_with("[]") {
            "[]"
        } else {
            ""
        };
        return Some(format!(
            "{}.{}{}",
            quote_ident("postgres", &enum_type.schema),
            quote_ident("postgres", &enum_type.name),
            array_suffix
        ));
    }
    if !matches!(value, Value::Text(_)) {
        return None;
    }
    postgres_array_cast_type(&column.data_type)
        .or_else(|| postgres_temporal_cast_type(&column.data_type))
        .or_else(|| postgres_numeric_cast_type(&column.data_type))
        .map(str::to_owned)
}

pub fn explain_statement(driver_id: &str, sql: &str) -> Option<String> {
    let prefix = match driver_id {
        "postgres" | "mysql" | "clickhouse" | "duckdb" => "EXPLAIN ",
        "sqlite" => "EXPLAIN QUERY PLAN ",
        _ => return None,
    };
    let trimmed = sql.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(format!("{prefix}{trimmed}"))
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
        let placeholder = placeholder_for(driver_id, params.len());
        let value_sql = if driver_id == "postgres" {
            postgres_text_cast_type(col, &values[i])
                .map(|type_name| format!("{placeholder}::text::{type_name}"))
                .unwrap_or(placeholder)
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

pub(crate) fn postgres_array_cast_type(data_type: &str) -> Option<&'static str> {
    let lowered = data_type.trim().to_ascii_lowercase();
    let element = lowered.strip_suffix("[]")?;
    let element = if let Some((base, modifier)) = element.split_once('(') {
        let modifier = modifier.strip_suffix(')')?;
        if modifier.is_empty()
            || !modifier
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b',' | b' '))
        {
            return None;
        }
        base.trim()
    } else {
        element
    };
    Some(match element {
        "bool" | "boolean" => "pg_catalog.bool[]",
        "bytea" => "pg_catalog.bytea[]",
        "name" => "pg_catalog.name[]",
        "int2" | "smallint" => "pg_catalog.int2[]",
        "int4" | "integer" | "int" => "pg_catalog.int4[]",
        "int8" | "bigint" => "pg_catalog.int8[]",
        "oid" => "pg_catalog.oid[]",
        "text" => "pg_catalog.text[]",
        "xml" => "pg_catalog.xml[]",
        "bit" => "pg_catalog.bit[]",
        "bit varying" | "varbit" => "pg_catalog.varbit[]",
        "float4" | "real" => "pg_catalog.float4[]",
        "float8" | "double precision" => "pg_catalog.float8[]",
        "varchar" | "character varying" => "pg_catalog.varchar[]",
        "char" | "bpchar" | "character" => "pg_catalog.bpchar[]",
        "numeric" | "decimal" => "pg_catalog.numeric[]",
        "uuid" => "pg_catalog.uuid[]",
        "pg_lsn" => "pg_catalog.pg_lsn[]",
        "date" => "pg_catalog.date[]",
        "time" | "time without time zone" => "pg_catalog.time[]",
        "timetz" | "time with time zone" => "pg_catalog.timetz[]",
        "timestamp" | "timestamp without time zone" => "pg_catalog.timestamp[]",
        "timestamptz" | "timestamp with time zone" => "pg_catalog.timestamptz[]",
        "interval" => "pg_catalog.interval[]",
        _ => return None,
    })
}

pub(crate) fn postgres_numeric_cast_type(data_type: &str) -> Option<&'static str> {
    if data_type.len() > 64 {
        return None;
    }
    let lowered = data_type.trim().to_ascii_lowercase();
    let (base, modifier) = match lowered.split_once('(') {
        Some((base, modifier)) => (base.trim(), Some(modifier.strip_suffix(')')?)),
        None => (lowered.as_str(), None),
    };
    if !matches!(base, "numeric" | "decimal") {
        return None;
    }
    if let Some(modifier) = modifier {
        let values: Vec<_> = modifier.split(',').map(str::trim).collect();
        if !matches!(values.len(), 1 | 2) || values.iter().any(|value| value.parse::<i32>().is_err()) {
            return None;
        }
    }
    Some("pg_catalog.numeric")
}

pub(crate) fn postgres_temporal_cast_type(data_type: &str) -> Option<&'static str> {
    let lowered = data_type.trim().to_ascii_lowercase();
    Some(match lowered.as_str() {
        "date" => "pg_catalog.date",
        "time" | "time without time zone" => "pg_catalog.time",
        "timetz" | "time with time zone" => "pg_catalog.timetz",
        "timestamp" | "timestamp without time zone" => "pg_catalog.timestamp",
        "timestamptz" | "timestamp with time zone" => "pg_catalog.timestamptz",
        _ => return None,
    })
}

pub fn build_keyed_delete(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    let mut params: Vec<Value> = Vec::with_capacity(pk_values.len());
    let where_clause = keyed_where_clause(driver_id, columns, &pk_indexes, pk_values, &mut params);
    let qualified = qualified_table(driver_id, schema, table);
    Ok((format!("DELETE FROM {qualified} WHERE {where_clause}"), params))
}

pub(super) fn checked_pk_indexes(columns: &[ColumnInfo], pk_values: &[Value]) -> Result<Vec<usize>, BuildSqlError> {
    let pk_indexes = collect_pk_indexes(columns);
    if pk_indexes.is_empty() {
        return Err(BuildSqlError::NoPrimaryKey);
    }
    if pk_values.len() != pk_indexes.len() {
        return Err(BuildSqlError::StaleColumns);
    }
    Ok(pk_indexes)
}

pub(super) fn keyed_where_clause(
    driver_id: &str,
    columns: &[ColumnInfo],
    pk_indexes: &[usize],
    pk_values: &[Value],
    params: &mut Vec<Value>,
) -> String {
    let clauses: Vec<String> = pk_indexes
        .iter()
        .zip(pk_values)
        .map(|(&col_idx, value)| {
            let ident = quote_ident(driver_id, &columns[col_idx].name);
            if matches!(value, Value::Null) {
                return format!("{ident} IS NULL");
            }
            let clause = format!("{ident} = {}", placeholder_for(driver_id, params.len()));
            params.push(value.clone());
            clause
        })
        .collect();
    clauses.join(" AND ")
}

pub(super) fn qualified_table(driver_id: &str, schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{}.{}", quote_ident(driver_id, s), quote_ident(driver_id, table)),
        None => quote_ident(driver_id, table),
    }
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
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn validate_ident_accepts_ordinary_and_quoted_names() {
        for name in ["users", "Order Details", "naïve", "a\"b", "a`b", "a]b"] {
            assert_eq!(validate_ident(name), Ok(()), "{name}");
        }
    }

    #[test]
    fn validate_ident_rejects_empty_overlong_and_control_characters() {
        assert_eq!(validate_ident(""), Err(IdentError::Empty));
        assert_eq!(validate_ident("   "), Err(IdentError::Empty));
        assert_eq!(
            validate_ident(&"a".repeat(MAX_IDENT_BYTES + 1)),
            Err(IdentError::TooLong)
        );
        for name in ["a\0b", "a\nb", "a\rb", "a\u{2028}b", "a\u{7f}b"] {
            assert_eq!(validate_ident(name), Err(IdentError::ControlCharacter), "{name:?}");
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

    /// The exact shape that broke identifier quoting: a trailing backslash
    /// consumes the closing backtick, so text after it parses as SQL rather
    /// than staying part of the identifier. Mirrors the literal-escaping
    /// regression test in sql_literal.rs.
    #[test]
    fn clickhouse_identifier_quoting_escapes_a_trailing_backslash() {
        assert_eq!(quote_ident("clickhouse", "evil\\"), "`evil\\\\`");
        assert_eq!(
            quote_ident("clickhouse", "evil\\`; DROP TABLE users; --"),
            "`evil\\\\``; DROP TABLE users; --`"
        );
    }

    #[test]
    fn mysql_identifier_quoting_does_not_touch_a_backslash() {
        // MySQL identifiers (unlike its string literals) do not treat
        // backslash as an escape character, so doubling it here would
        // corrupt the identifier instead of protecting it.
        assert_eq!(quote_ident("mysql", "evil\\"), "`evil\\`");
    }

    #[test]
    fn quote_ident_strips_control_characters_from_an_invalid_identifier() {
        assert_eq!(quote_ident("postgres", "a\nb"), "\"ab\"");
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
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
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
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
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
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
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
    fn value_contract_postgres_temporal_insert_cast_is_limited_to_postgres_text_values() {
        let mut date = col("value", false);
        date.data_type = "date".into();
        let (sql, _) = build_insert_from_draft(
            "postgres",
            None,
            "dates",
            std::slice::from_ref(&date),
            &[Value::Text("-infinity".into())],
        )
        .unwrap();
        assert_eq!(
            sql,
            "INSERT INTO \"dates\" (\"value\") VALUES ($1::text::pg_catalog.date)"
        );

        let native_date = Value::Date(chrono::NaiveDate::from_ymd_opt(2001, 2, 3).unwrap());
        let (sql, _) =
            build_insert_from_draft("postgres", None, "dates", std::slice::from_ref(&date), &[native_date]).unwrap();
        assert_eq!(sql, "INSERT INTO \"dates\" (\"value\") VALUES ($1)");

        let (sql, _) =
            build_insert_from_draft("mysql", None, "dates", &[date], &[Value::Text("-infinity".into())]).unwrap();
        assert_eq!(sql, "INSERT INTO `dates` (`value`) VALUES (?)");
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

    #[test]
    fn explain_uses_the_engine_plan_form() {
        assert_eq!(
            explain_statement("postgres", "SELECT 1").as_deref(),
            Some("EXPLAIN SELECT 1")
        );
        assert_eq!(
            explain_statement("sqlite", "  SELECT 1  ").as_deref(),
            Some("EXPLAIN QUERY PLAN SELECT 1")
        );
        assert_eq!(
            explain_statement("mysql", "SELECT 1").as_deref(),
            Some("EXPLAIN SELECT 1")
        );
    }

    #[test]
    fn explain_is_unsupported_for_engines_without_a_single_statement_plan() {
        for driver_id in ["mssql", "mongodb", "redis"] {
            assert_eq!(explain_statement(driver_id, "SELECT 1"), None, "driver: {driver_id}");
        }
    }

    #[test]
    fn explain_rejects_empty_sql() {
        assert_eq!(explain_statement("postgres", "   "), None);
    }

    #[test]
    fn a_keyed_update_binds_new_values_then_every_key_component_in_order() {
        let columns = [col("tenant", true), col("note", false), col("code", true)];
        let (sql, params) = build_keyed_update(
            "mssql",
            Some("dbo"),
            "t",
            &columns,
            &[(1, Value::Text("edited".into()))],
            &[Value::Int(9_007_199_254_740_993), Value::Text("a".into())],
        )
        .unwrap();
        assert_eq!(
            sql,
            "UPDATE [dbo].[t] SET [note] = @P1 WHERE [tenant] = @P2 AND [code] = @P3"
        );
        assert_eq!(
            params,
            vec![
                Value::Text("edited".into()),
                Value::Int(9_007_199_254_740_993),
                Value::Text("a".into())
            ]
        );
    }

    #[test]
    fn value_contract_postgres_text_array_updates_cast_through_text_to_a_builtin_array_type() {
        let mut columns = [col("id", true), col("value", false)];
        columns[1].data_type = "integer[]".into();
        let (sql, params) = build_keyed_update(
            "postgres",
            None,
            "t",
            &columns,
            &[(1, Value::Text("{3,NULL,5}".into()))],
            &[Value::Int(1)],
        )
        .unwrap();

        assert_eq!(
            sql,
            r#"UPDATE "t" SET "value" = $1::text::pg_catalog.int4[] WHERE "id" = $2"#
        );
        assert_eq!(params, vec![Value::Text("{3,NULL,5}".into()), Value::Int(1)]);

        let mut insert_columns = [col("value", false)];
        insert_columns[0].data_type = "float8[]".into();
        let (sql, params) = build_insert_from_draft(
            "postgres",
            None,
            "t",
            &insert_columns,
            &[Value::Text("{3,NULL,5}".into())],
        )
        .unwrap();
        assert_eq!(
            sql,
            r#"INSERT INTO "t" ("value") VALUES ($1::text::pg_catalog.float8[])"#
        );
        assert_eq!(params, vec![Value::Text("{3,NULL,5}".into())]);

        let (sql, _) =
            build_insert_from_draft("mysql", None, "t", &insert_columns, &[Value::Text("{3,NULL,5}".into())]).unwrap();
        assert_eq!(sql, "INSERT INTO `t` (`value`) VALUES (?)");
    }

    #[path = "postgres_array_cast_tests.rs"]
    mod postgres_array_cast_tests;

    #[path = "postgres_domain_cast_tests.rs"]
    mod postgres_domain_cast_tests;

    #[test]
    fn postgres_typed_numeric_updates_keep_the_native_placeholder() {
        let mut columns = [col("id", true), col("amount", false)];
        columns[1].data_type = "numeric(80, 40)".into();
        let value = Value::Decimal("12.50".parse().unwrap());
        let (sql, params) = build_keyed_update(
            "postgres",
            None,
            "ledger",
            &columns,
            &[(1, value.clone())],
            &[Value::Int(7)],
        )
        .unwrap();

        assert_eq!(sql, r#"UPDATE "ledger" SET "amount" = $1 WHERE "id" = $2"#);
        assert_eq!(params, vec![value, Value::Int(7)]);
    }

    #[test]
    fn postgres_numeric_cast_does_not_interpolate_untrusted_metadata() {
        assert_eq!(
            postgres_numeric_cast_type("NUMERIC(80, 40)"),
            Some("pg_catalog.numeric")
        );
        assert_eq!(postgres_numeric_cast_type("decimal(10)"), Some("pg_catalog.numeric"));
        for type_name in ["text", "numeric(80, 40); DROP TABLE t", "numeric(,)"] {
            assert_eq!(postgres_numeric_cast_type(type_name), None, "{type_name}");
        }
        let at_limit = format!("numeric({}1,2)", " ".repeat(64 - "numeric(1,2)".len()));
        assert_eq!(at_limit.len(), 64);
        assert_eq!(postgres_numeric_cast_type(&at_limit), Some("pg_catalog.numeric"));
        let over_limit = format!("numeric({}1,2)", " ".repeat(53));
        assert_eq!(over_limit.len(), 65);
        assert_eq!(postgres_numeric_cast_type(&over_limit), None);

        let mut columns = [col("id", true), col("amount", false)];
        columns[1].data_type = "text".into();
        let (sql, _) = build_keyed_update(
            "postgres",
            None,
            "ledger",
            &columns,
            &[(1, Value::Text("x".into()))],
            &[Value::Int(1)],
        )
        .unwrap();
        assert_eq!(sql, r#"UPDATE "ledger" SET "amount" = $1 WHERE "id" = $2"#);
    }

    #[test]
    fn a_keyed_delete_matches_a_null_key_component_with_is_null() {
        let columns = [col("a", true), col("b", true)];
        let (sql, params) = build_keyed_delete("postgres", None, "t", &columns, &[Value::Null, Value::Int(2)]).unwrap();
        assert_eq!(sql, r#"DELETE FROM "t" WHERE "a" IS NULL AND "b" = $1"#);
        assert_eq!(params, vec![Value::Int(2)]);
    }

    #[test]
    fn keyed_statements_refuse_a_key_or_column_that_no_longer_fits_the_table() {
        let columns = [col("id", true), col("note", false)];
        assert!(matches!(
            build_keyed_delete("postgres", None, "t", &[col("note", false)], &[Value::Int(1)]),
            Err(BuildSqlError::NoPrimaryKey)
        ));
        assert!(matches!(
            build_keyed_delete("postgres", None, "t", &columns, &[Value::Int(1), Value::Int(2)]),
            Err(BuildSqlError::StaleColumns)
        ));
        assert!(matches!(
            build_keyed_update("postgres", None, "t", &columns, &[(2, Value::Null)], &[Value::Int(1)]),
            Err(BuildSqlError::StaleColumns)
        ));
    }
}
