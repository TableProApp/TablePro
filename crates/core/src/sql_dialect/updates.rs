use super::{
    BuildSqlError, build_update, checked_pk_indexes, keyed_where_clause, placeholder_for, postgres_text_cast_type,
    qualified_table, quote_ident,
};
use crate::{ColumnInfo, Value};

pub fn build_keyed_value_select(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    value_column: usize,
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    let value_column = columns.get(value_column).ok_or(BuildSqlError::StaleColumns)?;
    let mut params = Vec::with_capacity(pk_values.len());
    let where_clause = keyed_value_where_clause(driver_id, columns, &pk_indexes, pk_values, &mut params);
    let order = pk_indexes
        .iter()
        .map(|&index| format!("{} ASC", quote_ident(driver_id, &columns[index].name)))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT {} FROM {} WHERE {where_clause}{}",
        quote_ident(driver_id, &value_column.name),
        qualified_table(driver_id, schema, table),
        super::build_order_and_pagination(driver_id, Some(&order), 2, 0),
    );
    Ok((sql, params))
}

fn keyed_value_where_clause(
    driver_id: &str,
    columns: &[ColumnInfo],
    pk_indexes: &[usize],
    pk_values: &[Value],
    params: &mut Vec<Value>,
) -> String {
    pk_indexes
        .iter()
        .zip(pk_values)
        .map(|(&index, value)| {
            let column = &columns[index];
            let name = quote_ident(driver_id, &column.name);
            if matches!(value, Value::Null) {
                return format!("{name} IS NULL");
            }
            let placeholder = placeholder_for(driver_id, params.len());
            let typed = if driver_id == "postgres" {
                postgres_text_cast_type(column, value)
                    .map(|type_name| format!("{placeholder}::text::{type_name}"))
                    .unwrap_or(placeholder)
            } else {
                placeholder
            };
            params.push(value.clone());
            format!("{name} = {typed}")
        })
        .collect::<Vec<_>>()
        .join(" AND ")
}

pub fn build_keyed_update(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    edits: &[(usize, Value)],
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    if edits.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    if edits.iter().any(|(col_idx, _)| *col_idx >= columns.len()) {
        return Err(BuildSqlError::StaleColumns);
    }
    let mut params: Vec<Value> = Vec::with_capacity(edits.len() + pk_values.len());
    let set_clauses: Vec<String> = edits
        .iter()
        .map(|(col_idx, new_value)| {
            let mysql_empty_enum_or_set =
                driver_id == "mysql" && matches!(new_value, Value::Text(value) if value.is_empty()) && {
                    let data_type = columns[*col_idx].data_type.trim().to_ascii_lowercase();
                    data_type.starts_with("enum(") || data_type.starts_with("set(")
                };
            if mysql_empty_enum_or_set {
                return format!("{} = SPACE(0)", quote_ident(driver_id, &columns[*col_idx].name));
            }
            let placeholder = placeholder_for(driver_id, params.len());
            let value_sql = if driver_id == "postgres" {
                postgres_text_cast_type(&columns[*col_idx], new_value)
                    .map(|type_name| format!("{placeholder}::text::{type_name}"))
                    .unwrap_or(placeholder)
            } else {
                placeholder
            };
            let clause = format!("{} = {}", quote_ident(driver_id, &columns[*col_idx].name), value_sql);
            params.push(new_value.clone());
            clause
        })
        .collect();
    let where_clause = keyed_where_clause(driver_id, columns, &pk_indexes, pk_values, &mut params);
    let qualified = qualified_table(driver_id, schema, table);
    let sql = build_update(driver_id, &qualified, &set_clauses.join(", "), &where_clause);
    Ok((sql, params))
}

pub fn build_optimistic_keyed_update(
    driver_id: &str,
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    edits: &[(usize, Value, Value)],
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    if edits.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    if edits.iter().any(|(col_idx, _, _)| *col_idx >= columns.len()) {
        return Err(BuildSqlError::StaleColumns);
    }
    let mut assignments = Vec::with_capacity(edits.len());
    let mut params = Vec::with_capacity(edits.len() * 3 + pk_values.len());
    for (col_idx, _, new_value) in edits {
        let name = quote_ident(driver_id, &columns[*col_idx].name);
        let placeholder = placeholder_for(driver_id, params.len());
        let value_sql = if driver_id == "postgres" {
            postgres_text_cast_type(&columns[*col_idx], new_value)
                .map(|type_name| format!("{placeholder}::text::{type_name}"))
                .unwrap_or(placeholder)
        } else {
            placeholder
        };
        assignments.push(format!("{name} = {value_sql}"));
        params.push(new_value.clone());
    }
    let mut predicates = vec![keyed_where_clause(
        driver_id,
        columns,
        &pk_indexes,
        pk_values,
        &mut params,
    )];
    for (col_idx, old_value, _) in edits {
        if columns[*col_idx].primary_key {
            continue;
        }
        let name = quote_ident(driver_id, &columns[*col_idx].name);
        predicates.push(optimistic_predicate(
            driver_id,
            &name,
            &columns[*col_idx],
            old_value,
            &mut params,
        )?);
    }
    let qualified = qualified_table(driver_id, schema, table);
    Ok((
        build_update(
            driver_id,
            &qualified,
            &assignments.join(", "),
            &predicates.join(" AND "),
        ),
        params,
    ))
}

fn optimistic_predicate(
    driver_id: &str,
    name: &str,
    column: &crate::ColumnInfo,
    old_value: &Value,
    params: &mut Vec<Value>,
) -> Result<String, BuildSqlError> {
    let placeholder = placeholder_for(driver_id, params.len());
    let predicate = match driver_id {
        "postgres" => {
            let value_sql = postgres_text_cast_type(column, old_value)
                .map(|type_name| format!("{placeholder}::text::{type_name}"))
                .unwrap_or(placeholder);
            format!("{name} IS NOT DISTINCT FROM {value_sql}")
        }
        "sqlite" | "duckdb" => format!("{name} IS NOT DISTINCT FROM {placeholder}"),
        "mysql" => format!("{name} <=> {placeholder}"),
        "mssql" => {
            let next = placeholder_for(driver_id, params.len() + 1);
            params.push(old_value.clone());
            params.push(old_value.clone());
            return Ok(format!(
                "({name} = {placeholder} OR ({name} IS NULL AND {next} IS NULL))"
            ));
        }
        _ => return Err(BuildSqlError::UnsupportedDriver(driver_id.into())),
    };
    params.push(old_value.clone());
    Ok(predicate)
}

/// Build a MongoDB grid update with compare-and-set predicates for every
/// edited field. MongoDB's update adapter translates equality against BSON
/// NULL to an explicit-null type check, keeping missing fields distinct.
pub fn build_mongodb_keyed_update(
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    edits: &[(usize, Value, Value)],
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let driver_id = "mongodb";
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    if edits.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    if edits.iter().any(|(col_idx, _, _)| *col_idx >= columns.len()) {
        return Err(BuildSqlError::StaleColumns);
    }

    let mut params = Vec::with_capacity(edits.len() * 2 + pk_values.len());
    let set_clauses = edits
        .iter()
        .map(|(col_idx, _, new_value)| {
            let placeholder = placeholder_for(driver_id, params.len());
            params.push(new_value.clone());
            format!("{} = {placeholder}", quote_ident(driver_id, &columns[*col_idx].name))
        })
        .collect::<Vec<_>>();
    let mut where_clauses = vec![keyed_where_clause(
        driver_id,
        columns,
        &pk_indexes,
        pk_values,
        &mut params,
    )];
    for (col_idx, original_value, _) in edits {
        if columns[*col_idx].primary_key {
            continue;
        }
        let placeholder = placeholder_for(driver_id, params.len());
        where_clauses.push(format!(
            "{} = {placeholder}",
            quote_ident(driver_id, &columns[*col_idx].name)
        ));
        params.push(original_value.clone());
    }
    let qualified = qualified_table(driver_id, schema, table);
    let sql = build_update(
        driver_id,
        &qualified,
        &set_clauses.join(", "),
        &where_clauses.join(" AND "),
    );
    Ok((sql, params))
}

pub fn build_mongodb_keyed_delete(
    schema: Option<&str>,
    table: &str,
    columns: &[ColumnInfo],
    original_values: &[Value],
    pk_values: &[Value],
) -> Result<(String, Vec<Value>), BuildSqlError> {
    let driver_id = "mongodb";
    if original_values.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            got: original_values.len(),
        });
    }
    let pk_indexes = checked_pk_indexes(columns, pk_values)?;
    let mut params = Vec::with_capacity(pk_values.len() + columns.len() - pk_indexes.len());
    let mut where_clauses = vec![keyed_where_clause(
        driver_id,
        columns,
        &pk_indexes,
        pk_values,
        &mut params,
    )];
    for (column_index, (column, original_value)) in columns.iter().zip(original_values).enumerate() {
        if pk_indexes.contains(&column_index) {
            continue;
        }
        if matches!(original_value, Value::Undecodable(kind) if kind != "missing BSON field") {
            return Err(BuildSqlError::UnrepresentableValue {
                column: column.name.clone(),
            });
        }
        let placeholder = placeholder_for(driver_id, params.len());
        where_clauses.push(format!("{} = {placeholder}", quote_ident(driver_id, &column.name)));
        params.push(original_value.clone());
    }
    let snapshot_fields = columns
        .iter()
        .zip(original_values)
        .filter(|(_, value)| !matches!(value, Value::Undecodable(kind) if kind == "missing BSON field"))
        .map(|(column, _)| serde_json::Value::String(column.name.clone()))
        .collect();
    where_clauses.push("tablepro_mongodb_exact_field_set(?)".into());
    params.push(Value::Json(serde_json::Value::Array(snapshot_fields)));
    let qualified = qualified_table(driver_id, schema, table);
    Ok((
        format!("DELETE FROM {qualified} WHERE {}", where_clauses.join(" AND ")),
        params,
    ))
}

#[cfg(test)]
mod tests {
    use super::{
        build_keyed_update, build_keyed_value_select, build_mongodb_keyed_delete, build_mongodb_keyed_update,
        build_optimistic_keyed_update,
    };
    use crate::{ColumnInfo, Value};

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: !primary_key,
            primary_key,
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
    fn mongodb_update_guards_edited_fields_with_original_values() {
        let columns = [column("_id", true), column("payload", false)];
        let (sql, params) = build_mongodb_keyed_update(
            Some("appdb"),
            "records",
            &columns,
            &[(1, Value::Text("before".into()), Value::Text("edited".into()))],
            &[Value::Text("id-1".into())],
        )
        .unwrap();
        assert_eq!(
            sql,
            "UPDATE \"appdb\".\"records\" SET \"payload\" = ? WHERE \"_id\" = ? AND \"payload\" = ?"
        );
        assert_eq!(
            params,
            vec![
                Value::Text("edited".into()),
                Value::Text("id-1".into()),
                Value::Text("before".into())
            ]
        );
    }

    #[test]
    fn mongodb_update_keeps_null_original_value_as_guard_parameter() {
        let columns = [column("_id", true), column("payload", false)];
        let (_, params) = build_mongodb_keyed_update(
            Some("appdb"),
            "records",
            &columns,
            &[(1, Value::Null, Value::Text("edited".into()))],
            &[Value::Text("id-1".into())],
        )
        .unwrap();
        assert_eq!(
            params,
            vec![Value::Text("edited".into()), Value::Text("id-1".into()), Value::Null]
        );
    }

    #[test]
    fn mongodb_delete_guards_every_non_key_value_including_null_and_missing() {
        let columns = [column("_id", true), column("nullable", false), column("missing", false)];
        let (sql, params) = build_mongodb_keyed_delete(
            Some("appdb"),
            "records",
            &columns,
            &[
                Value::Json(serde_json::Value::String("id-1".into())),
                Value::Null,
                Value::Undecodable("missing BSON field".into()),
            ],
            &[Value::Json(serde_json::Value::String("id-1".into()))],
        )
        .unwrap();
        assert_eq!(
            sql,
            "DELETE FROM \"appdb\".\"records\" WHERE \"_id\" = ? AND \"nullable\" = ? AND \"missing\" = ? AND tablepro_mongodb_exact_field_set(?)"
        );
        assert_eq!(
            params,
            vec![
                Value::Json(serde_json::Value::String("id-1".into())),
                Value::Null,
                Value::Undecodable("missing BSON field".into()),
                Value::Json(serde_json::json!(["_id", "nullable"]))
            ]
        );
    }

    #[test]
    fn mongodb_delete_refuses_other_undecodable_snapshot_values() {
        let columns = [column("_id", true), column("payload", false)];
        let error = build_mongodb_keyed_delete(
            None,
            "records",
            &columns,
            &[Value::Int(1), Value::Undecodable("NUMERIC".into())],
            &[Value::Int(1)],
        )
        .unwrap_err();
        assert!(
            matches!(error, crate::sql_dialect::BuildSqlError::UnrepresentableValue { column } if column == "payload")
        );
    }

    #[test]
    fn ordinary_keyed_updates_keep_the_existing_primary_key_filter() {
        let columns = [column("id", true), column("payload", false)];
        let (sql, params) = build_keyed_update(
            "postgres",
            None,
            "records",
            &columns,
            &[(1, Value::Text("edited".into()))],
            &[Value::Int(7)],
        )
        .unwrap();
        assert_eq!(sql, "UPDATE \"records\" SET \"payload\" = $1 WHERE \"id\" = $2");
        assert_eq!(params, vec![Value::Text("edited".into()), Value::Int(7)]);
    }

    #[test]
    fn optimistic_updates_compare_the_original_value_with_null_safe_dialect_syntax() {
        let mut columns = [column("id", true), column("payload", false)];
        columns[1].nullable = true;
        for (driver, expected) in [
            ("postgres", "\"payload\" IS NOT DISTINCT FROM $3"),
            ("sqlite", "\"payload\" IS NOT DISTINCT FROM ?"),
            ("mysql", "`payload` <=> ?"),
            ("mssql", "([payload] = @P3 OR ([payload] IS NULL AND @P4 IS NULL))"),
        ] {
            let (sql, params) = build_optimistic_keyed_update(
                driver,
                None,
                "records",
                &columns,
                &[(1, Value::Null, Value::Text("edited".into()))],
                &[Value::Int(7)],
            )
            .unwrap();
            assert!(sql.contains(expected), "{driver}: {sql}");
            assert_eq!(params.last(), Some(&Value::Null));
            assert_eq!(params.first(), Some(&Value::Text("edited".into())));
        }
    }

    #[test]
    fn mysql_empty_enum_and_set_keyed_values_use_a_server_empty_string_expression() {
        let mut mood = column("mood", false);
        mood.data_type = "ENUM('', 'ready')".into();
        let mut permissions = column("permissions", false);
        permissions.data_type = "set('read', 'write')".into();
        let columns = [column("id", true), mood, permissions, column("note", false)];
        let (sql, params) = build_keyed_update(
            "mysql",
            None,
            "records",
            &columns,
            &[
                (1, Value::Text(String::new())),
                (2, Value::Text(String::new())),
                (3, Value::Text(String::new())),
            ],
            &[Value::Int(7)],
        )
        .unwrap();

        assert_eq!(
            sql,
            "UPDATE `records` SET `mood` = SPACE(0), `permissions` = SPACE(0), `note` = ? WHERE `id` = ?"
        );
        assert_eq!(params, vec![Value::Text(String::new()), Value::Int(7)]);
    }

    #[test]
    fn keyed_value_select_quotes_target_binds_composite_keys_and_caps_duplicates() {
        let columns = [column("tenant", true), column("id", true), column("payload", false)];
        let (sql, params) = build_keyed_value_select(
            "postgres",
            Some("odd\"schema"),
            "records",
            &columns,
            2,
            &[Value::Text("acme".into()), Value::Int(7)],
        )
        .unwrap();

        assert_eq!(
            sql,
            "SELECT \"payload\" FROM \"odd\"\"schema\".\"records\" WHERE \"tenant\" = $1 AND \"id\" = $2 ORDER BY \"tenant\" ASC, \"id\" ASC LIMIT 2 OFFSET 0"
        );
        assert_eq!(params, vec![Value::Text("acme".into()), Value::Int(7)]);
    }

    #[test]
    fn keyed_value_select_casts_postgres_enum_and_domain_keys() {
        let mut enum_key = column("status", true);
        enum_key.data_type = "status_type".into();
        enum_key.enum_type = Some(crate::QualifiedTypeName {
            schema: "app".into(),
            name: "status_type".into(),
        });
        let mut domain_key = column("domain_status", true);
        domain_key.data_type = "domain_status_type".into();
        domain_key.domain_type = Some(crate::QualifiedTypeName {
            schema: "app".into(),
            name: "domain_status_type".into(),
        });
        let columns = [enum_key, domain_key, column("payload", false)];
        let (sql, params) = build_keyed_value_select(
            "postgres",
            None,
            "records",
            &columns,
            2,
            &[Value::Text("ready".into()), Value::Text("open".into())],
        )
        .unwrap();

        assert_eq!(
            sql,
            "SELECT \"payload\" FROM \"records\" WHERE \"status\" = $1::text::\"app\".\"status_type\" AND \"domain_status\" = $2::text::\"app\".\"domain_status_type\" ORDER BY \"status\" ASC, \"domain_status\" ASC LIMIT 2 OFFSET 0"
        );
        assert_eq!(params, vec![Value::Text("ready".into()), Value::Text("open".into())]);
    }

    #[test]
    fn keyed_value_select_requires_a_primary_key_and_existing_column() {
        let no_key = [column("payload", false)];
        assert!(matches!(
            build_keyed_value_select("postgres", None, "records", &no_key, 0, &[]),
            Err(crate::sql_dialect::BuildSqlError::NoPrimaryKey)
        ));
        let keyed = [column("id", true)];
        assert!(matches!(
            build_keyed_value_select("postgres", None, "records", &keyed, 1, &[Value::Int(1)]),
            Err(crate::sql_dialect::BuildSqlError::StaleColumns)
        ));
    }
}
