//! Tool catalogue. Names are stable; MCP clients bind to these strings.

pub const TOOL_NAMES: &[&str] = &[
    "list_connections",
    "list_tables",
    "list_objects",
    "describe_table",
    "execute_query",
    "execute_write",
    "explain_query",
    "export_data",
    "table_schema",
    "count_rows",
    "browse_table",
];

use serde_json::{Value as JsonValue, json};
use tablepro_core::export::{
    CsvOptions, unique_csv_null_marker, write_csv_header_with_options, write_csv_row_with_columns_and_options,
};

use uuid::Uuid;

use crate::bridge::{McpBridge, TableSchema, WriteOutcome};
use crate::tokens::McpToken;

pub async fn dispatch(bridge: &McpBridge, token: &McpToken, name: &str, args: JsonValue) -> Result<JsonValue, String> {
    match name {
        "list_connections" => {
            let list = bridge.list_connections(token).await?;
            Ok(json!(
                list.into_iter()
                    .map(|c| json!({
                        "id": c.id,
                        "name": c.name,
                        "driver_id": c.driver_id,
                        "environment": c.environment,
                        "read_only": c.read_only,
                    }))
                    .collect::<Vec<_>>()
            ))
        }
        "list_tables" => {
            let id = parse_uuid(&args, "connection_id")?;
            let tables = bridge.list_tables(token, id).await?;
            Ok(json!(
                tables
                    .into_iter()
                    .map(|t| json!({"schema": t.schema, "name": t.name}))
                    .collect::<Vec<_>>()
            ))
        }
        "list_objects" => {
            let id = parse_uuid(&args, "connection_id")?;
            let kind = parse_catalog_kind(&args)?;
            let schema = args.get("schema").and_then(|v| v.as_str()).map(str::to_string);
            let objects = bridge.list_objects(token, id, kind, schema).await?;
            Ok(json!(objects))
        }
        "describe_table" => {
            let id = parse_uuid(&args, "connection_id")?;
            let table = args
                .get("table")
                .and_then(|v| v.as_str())
                .ok_or("missing table")?
                .to_string();
            let schema = args.get("schema").and_then(|v| v.as_str()).map(|s| s.to_string());
            let columns = bridge.describe_table(token, id, schema, table).await?;
            Ok(json!(
                columns
                    .into_iter()
                    .map(|column| json!({
                        "name": column.name,
                        "data_type": column.data_type,
                        "nullable": column.nullable,
                        "primary_key": column.primary_key,
                    }))
                    .collect::<Vec<_>>()
            ))
        }
        "execute_query" => {
            let id = parse_uuid(&args, "connection_id")?;
            let sql = args
                .get("sql")
                .and_then(|v| v.as_str())
                .ok_or("missing sql")?
                .to_string();
            let result = bridge.execute_query(token, id, &sql).await?;
            let first = result.result_sets.first();
            Ok(json!({
                "columns": first.map(|set| set.columns.iter().map(|c| &c.name).collect::<Vec<_>>()).unwrap_or_default(),
                "rows": first.into_iter().flat_map(|set| &set.rows).map(|r| {
                    r.iter().map(value_to_json).collect::<Vec<_>>()
                }).collect::<Vec<_>>(),
                "additional_result_sets": result.result_sets.iter().skip(1).map(|set| json!({
                    "columns": set.columns.iter().map(|c| &c.name).collect::<Vec<_>>(),
                    "rows": set.rows.iter().map(|r| r.iter().map(value_to_json).collect::<Vec<_>>()).collect::<Vec<_>>(),
                    "truncated": set.truncated,
                })).collect::<Vec<_>>(),
                "truncated": result.truncated,
            }))
        }
        "execute_write" => {
            let id = parse_uuid(&args, "connection_id")?;
            let sql = args
                .get("sql")
                .and_then(|v| v.as_str())
                .ok_or("missing sql")?
                .to_string();
            let preview = args.get("preview").and_then(|v| v.as_bool()).unwrap_or(true);
            let outcome = bridge.execute_write(token, id, &sql, preview).await?;
            Ok(match outcome {
                WriteOutcome::Preview {
                    rows_affected,
                    rolled_back,
                } => json!({
                    "preview": true,
                    "rows_affected": rows_affected,
                    "rolled_back": rolled_back,
                    "message": "Write previewed inside a transaction and rolled back. Re-call with preview=false after approval to commit.",
                }),
                WriteOutcome::Committed { rows_affected } => json!({
                    "preview": false,
                    "rows_affected": rows_affected,
                    "committed": true,
                }),
            })
        }
        "explain_query" => {
            let id = parse_uuid(&args, "connection_id")?;
            let sql = args
                .get("sql")
                .and_then(|v| v.as_str())
                .ok_or("missing sql")?
                .to_string();
            let result = bridge.explain_query(token, id, &sql).await?;
            Ok(json!({
                "plan_rows": result.rows.iter().map(|r| {
                    r.iter().map(value_to_json).collect::<Vec<_>>()
                }).collect::<Vec<_>>(),
            }))
        }
        "export_data" => {
            let id = parse_uuid(&args, "connection_id")?;
            let sql = args
                .get("sql")
                .and_then(|v| v.as_str())
                .ok_or("missing sql")?
                .to_string();
            let format = args.get("format").and_then(|v| v.as_str()).unwrap_or("json");
            let control = bridge.start_connection_operation(token, id)?;
            let result = bridge
                .execute_query_controlled(token, id, &sql, None, control.clone())
                .await?;
            bridge.ensure_operation_active(&control)?;
            match format {
                "csv" => {
                    if result.result_sets.len() > 1 {
                        return Err("CSV export cannot represent multiple result sets; use JSON".into());
                    }
                    let first = result.result_sets.first();
                    let rows = first.map(|set| set.rows.as_slice()).unwrap_or_default();
                    let columns = first.map(|set| set.columns.as_slice()).unwrap_or_default();
                    let null_marker = unique_csv_null_marker(rows);
                    let options = CsvOptions {
                        null_to_empty: false,
                        null_marker: Some(null_marker.clone()),
                        sanitize_formulas: false,
                        ..CsvOptions::default()
                    };
                    let mut out: Vec<u8> = Vec::new();
                    write_csv_header_with_options(&mut out, columns, &options).map_err(|error| error.to_string())?;
                    for row in rows {
                        bridge.ensure_operation_active(&control)?;
                        write_csv_row_with_columns_and_options(&mut out, columns, row, &options)
                            .map_err(|error| error.to_string())?;
                    }
                    bridge.ensure_operation_active(&control)?;
                    let content = String::from_utf8(out).map_err(|error| error.to_string())?;
                    Ok(json!({"format": "csv", "content": content, "null_marker": null_marker}))
                }
                _ => {
                    let first = result.result_sets.first();
                    let first_rows = first.map(|set| set.rows.as_slice()).unwrap_or_default();
                    let first_columns = first.map(|set| set.columns.as_slice()).unwrap_or_default();
                    let mut rows = Vec::with_capacity(first_rows.len());
                    for row in first_rows {
                        bridge.ensure_operation_active(&control)?;
                        rows.push(row.iter().map(value_to_json).collect::<Vec<_>>());
                    }
                    bridge.ensure_operation_active(&control)?;
                    Ok(json!({
                        "format": "json",
                        "columns": first_columns.iter().map(|c| &c.name).collect::<Vec<_>>(),
                        "rows": rows,
                        "additional_result_sets": result.result_sets.iter().skip(1).map(|set| json!({
                            "columns": set.columns.iter().map(|c| &c.name).collect::<Vec<_>>(),
                            "rows": set.rows.iter().map(|r| r.iter().map(value_to_json).collect::<Vec<_>>()).collect::<Vec<_>>(),
                            "truncated": set.truncated,
                        })).collect::<Vec<_>>(),
                        "truncated": result.truncated,
                    }))
                }
            }
        }
        "table_schema" => {
            let id = parse_uuid(&args, "connection_id")?;
            let table = required_str(&args, "table")?;
            let schema = optional_str(&args, "schema");
            let schema_out = bridge.table_schema(token, id, schema, table).await?;
            Ok(table_schema_json(&schema_out))
        }
        "count_rows" => {
            let id = parse_uuid(&args, "connection_id")?;
            let table = required_str(&args, "table")?;
            let schema = optional_str(&args, "schema");
            let count = bridge.count_rows(token, id, schema, table).await?;
            Ok(json!({"row_count": count, "exact": true}))
        }
        "browse_table" => {
            let id = parse_uuid(&args, "connection_id")?;
            let table = required_str(&args, "table")?;
            let schema = optional_str(&args, "schema");
            let offset = parse_u64(&args, "offset", 0)?;
            let limit = parse_u64(&args, "limit", bridge.max_rows)?;
            let result = bridge.browse_table(token, id, schema, table, offset, limit).await?;
            Ok(json!({
                "offset": offset,
                "columns": result.columns.iter().map(|c| &c.name).collect::<Vec<_>>(),
                "rows": result.rows.iter().map(|r| {
                    r.iter().map(value_to_json).collect::<Vec<_>>()
                }).collect::<Vec<_>>(),
                "truncated": result.truncated,
            }))
        }
        other => Err(format!("unknown tool: {other}")),
    }
}

fn table_schema_json(schema: &TableSchema) -> JsonValue {
    json!({
        "columns": schema.columns.iter().map(|c| json!({
            "name": c.name,
            "data_type": c.data_type,
            "nullable": c.nullable,
            "primary_key": c.primary_key,
            "default_value": c.default_value,
            "is_auto_increment": c.is_auto_increment,
            "is_generated": c.is_generated,
        })).collect::<Vec<_>>(),
        "primary_key": schema.columns.iter().filter(|c| c.primary_key).map(|c| &c.name).collect::<Vec<_>>(),
        "indexes": schema.indexes.iter().map(|i| json!({
            "name": i.name,
            "columns": i.columns,
            "unique": i.unique,
            "primary": i.primary,
        })).collect::<Vec<_>>(),
        "foreign_keys": schema.foreign_keys.iter().map(|f| json!({
            "name": f.name,
            "columns": f.columns,
            "ref_schema": f.ref_schema,
            "ref_table": f.ref_table,
            "ref_columns": f.ref_columns,
            "on_delete": f.on_delete,
            "on_update": f.on_update,
        })).collect::<Vec<_>>(),
    })
}

fn required_str(args: &JsonValue, key: &str) -> Result<String, String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("missing {key}"))
}

fn optional_str(args: &JsonValue, key: &str) -> Option<String> {
    args.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
}

fn parse_u64(args: &JsonValue, key: &str, default: u64) -> Result<u64, String> {
    match args.get(key) {
        None | Some(JsonValue::Null) => Ok(default),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| format!("{key} must be a non-negative integer")),
    }
}

fn parse_catalog_kind(args: &JsonValue) -> Result<tablepro_core::CatalogObjectKind, String> {
    let raw = args.get("kind").and_then(|v| v.as_str()).ok_or("missing kind")?;
    tablepro_core::CatalogObjectKind::parse(raw).ok_or_else(|| {
        let known: Vec<&str> = tablepro_core::CatalogObjectKind::ALL
            .iter()
            .map(|k| k.as_str())
            .collect();
        format!("unknown kind {raw:?}; expected one of {}", known.join(", "))
    })
}

fn parse_uuid(args: &JsonValue, key: &str) -> Result<Uuid, String> {
    let s = args
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("missing {key}"))?;
    Uuid::parse_str(s).map_err(|e| e.to_string())
}

fn value_to_json(v: &tablepro_core::Value) -> JsonValue {
    match v {
        tablepro_core::Value::Null => JsonValue::Null,
        tablepro_core::Value::Bool(b) => json!(b),
        tablepro_core::Value::Int(i) => json!(i),
        tablepro_core::Value::Float(f) if !f.is_finite() => json!(f.to_string()),
        tablepro_core::Value::Float(f) => json!(f),
        tablepro_core::Value::Text(s) => json!(s),
        tablepro_core::Value::Bytes(b) => json!(format!("\\x{}", hex::encode(b))),
        tablepro_core::Value::Date(d) => json!(d.to_string()),
        tablepro_core::Value::Time(t) => json!(t.to_string()),
        tablepro_core::Value::DateTime(d) => json!(d.to_string()),
        tablepro_core::Value::TimestampTz(d) => json!(d.to_rfc3339()),
        tablepro_core::Value::Decimal(d) => json!(d.to_string()),
        tablepro_core::Value::Uuid(u) => json!(u.to_string()),
        tablepro_core::Value::Json(j) => j.clone(),
        tablepro_core::Value::Undecodable(type_name) => json!({ "undecodable": type_name }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_contract_nonfinite_numbers_remain_distinct_from_sql_null() {
        for number in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(
                value_to_json(&tablepro_core::Value::Float(number)),
                json!(number.to_string())
            );
        }
        assert_eq!(value_to_json(&tablepro_core::Value::Null), JsonValue::Null);
    }

    #[test]
    fn shared_query_history_is_not_exposed() {
        assert!(!TOOL_NAMES.contains(&"search_query_history"));
    }

    #[test]
    fn the_metadata_tools_are_advertised() {
        for name in ["table_schema", "count_rows", "browse_table"] {
            assert!(TOOL_NAMES.contains(&name), "{name}");
        }
    }

    #[test]
    fn pagination_arguments_refuse_a_negative_or_non_numeric_page() {
        assert_eq!(parse_u64(&json!({}), "offset", 0).unwrap(), 0);
        assert_eq!(parse_u64(&json!({"offset": 12}), "offset", 0).unwrap(), 12);
        assert!(parse_u64(&json!({"offset": -1}), "offset", 0).is_err());
        assert!(parse_u64(&json!({"offset": "3"}), "offset", 0).is_err());
        assert!(parse_u64(&json!({"offset": 1.5}), "offset", 0).is_err());
    }

    #[test]
    fn an_undecodable_value_is_reported_to_mcp_clients_not_hidden_as_null() {
        let json = value_to_json(&tablepro_core::Value::Undecodable("NUMERIC".into()));
        assert_ne!(json, JsonValue::Null);
        assert_eq!(json, json!({ "undecodable": "NUMERIC" }));
    }

    #[test]
    fn mongodb_extended_json_types_survive_mcp_value_conversion() {
        let extended = json!({
            "amount": {"$numberDecimal": "1E-6176"},
            "payload": {"$binary": {"base64": "AP9B", "subType": "80"}},
            "when": {"$date": {"$numberLong": "9223372036854775807"}},
        });
        assert_eq!(value_to_json(&tablepro_core::Value::Json(extended.clone())), extended);
    }
}
