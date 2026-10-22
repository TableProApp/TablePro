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
use crate::errors::McpToolError;
use crate::tokens::McpToken;

const VALUE_FORMAT: &str = "bookie-tagged-v1";

pub async fn dispatch(bridge: &McpBridge, token: &McpToken, name: &str, args: JsonValue) -> Result<JsonValue, String> {
    dispatch_structured(bridge, token, name, args)
        .await
        .map_err(|error| error.legacy_diagnostic())
}

pub(crate) async fn dispatch_structured(
    bridge: &McpBridge,
    token: &McpToken,
    name: &str,
    args: JsonValue,
) -> Result<JsonValue, McpToolError> {
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
                "value_format": VALUE_FORMAT,
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
            let outcome = bridge.execute_write_structured(token, id, &sql, preview).await?;
            Ok(match outcome {
                WriteOutcome::Preview {
                    rows_affected,
                    rolled_back,
                } => json!({
                    "value_format": VALUE_FORMAT,
                    "preview": true,
                    "rows_affected": u64_to_json(rows_affected),
                    "rolled_back": rolled_back,
                    "message": "Write previewed inside a transaction and rolled back. Re-call with preview=false after approval to commit.",
                }),
                WriteOutcome::Committed { rows_affected } => json!({
                    "value_format": VALUE_FORMAT,
                    "preview": false,
                    "rows_affected": u64_to_json(rows_affected),
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
                "value_format": VALUE_FORMAT,
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
                    Ok(
                        json!({"format": "csv", "content": content, "null_marker": null_marker, "truncated": result.truncated}),
                    )
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
                        "value_format": VALUE_FORMAT,
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
            Ok(json!({"value_format": VALUE_FORMAT, "row_count": u64_to_json(count), "exact": true}))
        }
        "browse_table" => {
            let id = parse_uuid(&args, "connection_id")?;
            let table = required_str(&args, "table")?;
            let schema = optional_str(&args, "schema");
            let offset = parse_u64(&args, "offset", 0)?;
            let limit = parse_u64(&args, "limit", bridge.max_rows)?;
            let result = bridge.browse_table(token, id, schema, table, offset, limit).await?;
            Ok(json!({
                "value_format": VALUE_FORMAT,
                "offset": u64_to_json(offset),
                "columns": result.columns.iter().map(|c| &c.name).collect::<Vec<_>>(),
                "rows": result.rows.iter().map(|r| {
                    r.iter().map(value_to_json).collect::<Vec<_>>()
                }).collect::<Vec<_>>(),
                "truncated": result.truncated,
            }))
        }
        other => Err(format!("unknown tool: {other}").into()),
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
            .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
            .ok_or_else(|| format!("{key} must be a non-negative integer or an unsigned decimal string")),
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
        tablepro_core::Value::Null => json!({"$type": "null"}),
        tablepro_core::Value::Bool(value) => tagged_value("bool", json!(value)),
        tablepro_core::Value::Int(value) => tagged_value("int64", json!(value.to_string())),
        tablepro_core::Value::Float(value) => tagged_value("float64", json!(value.to_string())),
        tablepro_core::Value::Text(value) => tagged_value("text", json!(value)),
        tablepro_core::Value::Bytes(value) => tagged_value("bytes_hex", json!(hex::encode(value))),
        tablepro_core::Value::Date(value) => tagged_value("date", json!(value.to_string())),
        tablepro_core::Value::Time(value) => tagged_value("time", json!(value.to_string())),
        tablepro_core::Value::DateTime(value) => tagged_value("datetime", json!(value.to_string())),
        tablepro_core::Value::TimestampTz(value) => tagged_value("timestamp_tz", json!(value.to_rfc3339())),
        tablepro_core::Value::Decimal(value) => tagged_value("decimal", json!(value.to_string())),
        tablepro_core::Value::Uuid(value) => tagged_value("uuid", json!(value.to_string())),
        tablepro_core::Value::Json(value) => tagged_value("json", json_value_to_tagged(value)),
        tablepro_core::Value::JsonText(value) => tagged_value("json_text", json!(value)),
        tablepro_core::Value::Undecodable(value) => tagged_value("undecodable", json!(value)),
    }
}

fn tagged_value(value_type: &str, value: JsonValue) -> JsonValue {
    json!({"$type": value_type, "value": value})
}

fn json_value_to_tagged(value: &JsonValue) -> JsonValue {
    match value {
        JsonValue::Null => tagged_value("json_null", JsonValue::Null),
        JsonValue::Bool(value) => tagged_value("json_bool", json!(value)),
        JsonValue::Number(value) => tagged_value("json_number", json!(value.to_string())),
        JsonValue::String(value) => tagged_value("json_string", json!(value)),
        JsonValue::Array(values) => tagged_value(
            "json_array",
            json!(values.iter().map(json_value_to_tagged).collect::<Vec<_>>()),
        ),
        JsonValue::Object(values) => tagged_value(
            "json_object",
            json!(
                values
                    .iter()
                    .map(|(key, value)| (key.clone(), json_value_to_tagged(value)))
                    .collect::<serde_json::Map<_, _>>()
            ),
        ),
    }
}

fn u64_to_json(value: u64) -> JsonValue {
    tagged_value("uint64", json!(value.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_contract_nonfinite_numbers_remain_distinct_from_sql_null() {
        for number in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(
                value_to_json(&tablepro_core::Value::Float(number)),
                json!({"$type": "float64", "value": number.to_string()})
            );
        }
        assert_eq!(value_to_json(&tablepro_core::Value::Null), json!({"$type": "null"}));
    }

    #[test]
    fn tagged_mcp_values_preserve_integer_kind_and_wide_digits() {
        for value in [i64::MIN, -9_007_199_254_740_993, 9_007_199_254_740_993, i64::MAX] {
            assert_eq!(
                value_to_json(&tablepro_core::Value::Int(value)),
                json!({"$type": "int64", "value": value.to_string()})
            );
        }
    }

    #[test]
    fn tagged_nested_json_preserves_wide_integer_and_decimal_tokens() {
        let value: JsonValue =
            serde_json::from_str("[9007199254740993,-9007199254740993,{\"fraction\":1.234567890123456789}]").unwrap();

        assert_eq!(
            value_to_json(&tablepro_core::Value::Json(Box::new(value))),
            json!({
                "$type": "json",
                "value": {
                    "$type": "json_array",
                    "value": [
                        {"$type": "json_number", "value": "9007199254740993"},
                        {"$type": "json_number", "value": "-9007199254740993"},
                        {
                            "$type": "json_object",
                            "value": {
                                "fraction": {"$type": "json_number", "value": "1.234567890123456789"}
                            }
                        }
                    ]
                }
            })
        );
    }

    #[test]
    fn tagged_json_text_preserves_source_tokens_and_duplicate_keys() {
        let source = r#"{ "wide": 9007199254740993, "duplicate": 1, "duplicate": 2, "fraction": 1.2300e+20 }"#;

        assert_eq!(
            value_to_json(&tablepro_core::Value::JsonText(source.into())),
            json!({"$type": "json_text", "value": source})
        );
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
        assert_eq!(
            parse_u64(&json!({"offset": "18446744073709551615"}), "offset", 0).unwrap(),
            u64::MAX
        );
        assert!(parse_u64(&json!({"offset": -1}), "offset", 0).is_err());
        assert!(parse_u64(&json!({"offset": "18446744073709551616"}), "offset", 0).is_err());
        assert!(parse_u64(&json!({"offset": "1.5"}), "offset", 0).is_err());
        assert!(parse_u64(&json!({"offset": 1.5}), "offset", 0).is_err());
    }

    #[test]
    fn an_undecodable_value_is_reported_to_mcp_clients_not_hidden_as_null() {
        let json = value_to_json(&tablepro_core::Value::Undecodable("NUMERIC".into()));
        assert_ne!(json, JsonValue::Null);
        assert_eq!(json, json!({"$type": "undecodable", "value": "NUMERIC"}));
    }

    #[test]
    fn mongodb_extended_json_types_survive_mcp_value_conversion() {
        let extended = json!({
            "amount": {"$numberDecimal": "1E-6176"},
            "payload": {"$binary": {"base64": "AP9B", "subType": "80"}},
            "when": {"$date": {"$numberLong": "9223372036854775807"}},
        });
        assert_eq!(
            value_to_json(&tablepro_core::Value::Json(Box::new(extended.clone()))),
            json!({
                "$type": "json",
                "value": json_value_to_tagged(&extended)
            })
        );
    }
}
