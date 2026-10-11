use std::{collections::HashMap, iter};

use futures::stream::StreamExt;
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgRow, PgTypeInfo, PgTypeKind};
use sqlx::{Column, Connection, Executor, Pool, Postgres, Row, SqlSafeStr, Statement, TypeInfo, ValueRef};
use tablepro_core::{
    ColumnInfo, DriverError, ExecResult, MAX_QUERY_ROWS, QualifiedTypeName, QueryResult, QueryResultBudget, Value,
};

use super::params::{bind_pg_params, describe_query_parameters, needs_text_type_inference, pg_parameter_type_infos};
use super::{array, decode, map_sqlx_error, numeric, temporal};

#[derive(Clone, Copy)]
pub(super) struct QueryStop<'a> {
    pub pool: &'a Pool<Postgres>,
    pub backend_pid: i32,
}

async fn stop_server_query<S>(stop: Option<QueryStop<'_>>, stream: &mut S)
where
    S: futures::Stream<Item = Result<PgRow, sqlx::Error>> + Unpin,
{
    let Some(stop) = stop else {
        return;
    };
    if let Err(error) = super::request_cancellation(stop.pool, stop.backend_pid).await {
        tracing::warn!(%error, "the server was not told to stop a capped query");
        return;
    }
    while stream.next().await.is_some() {}
}

pub(super) async fn query_connection(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
    stop: Option<QueryStop<'_>>,
) -> Result<QueryResult, DriverError> {
    let result = query_connection_once(connection, sql, params, stop).await;
    // A concurrent DROP/CREATE can leave a cached plan pointing at the old
    // OID. PostgreSQL raises this before executing the statement, so clear
    // SQLx's per-connection caches and retry the same operation once.
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return query_connection_once(connection, sql, params, stop).await;
    }
    result
}

pub(super) async fn query_connection_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
    stop: Option<QueryStop<'_>>,
) -> Result<QueryResult, DriverError> {
    let description = if needs_text_type_inference(params) {
        Some(describe_query_parameters(connection, sql, params).await?)
    } else {
        None
    };
    let inferred_text_types = description
        .as_ref()
        .map_or(&[][..], |description| description.inferred_text_types.as_slice());
    let query = bind_pg_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params, inferred_text_types)?;
    let mut stream = query.fetch(&mut **connection);
    let (mut result, mut type_infos, mut column_origins) = collect_query_rows(&mut stream, MAX_QUERY_ROWS).await?;
    if result.truncated {
        stop_server_query(stop, &mut stream).await;
    }
    drop(stream);
    if result.columns.is_empty() && result.rows.is_empty() {
        if let Some(description) = description {
            result.columns = description.columns;
            type_infos = description.column_type_infos;
            column_origins = description.column_origins;
        } else {
            let parameter_types = pg_parameter_type_infos(params);
            let statement = connection
                .prepare_with(sqlx::AssertSqlSafe(sql).into_sql_str(), &parameter_types)
                .await
                .map_err(map_sqlx_error)?;
            result.columns = statement_columns(statement.columns());
            type_infos = statement_type_infos(statement.columns());
            column_origins = statement_column_origins(statement.columns());
        }
    }
    refresh_enum_type_names(connection, &mut result.columns, &type_infos).await?;
    refresh_domain_column_names(connection, &mut result.columns, &column_origins).await?;
    Ok(result)
}

pub(super) async fn execute_connection(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
) -> Result<ExecResult, DriverError> {
    let result = execute_connection_once(connection, sql, params).await;
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return execute_connection_once(connection, sql, params).await;
    }
    result
}

pub(super) async fn execute_connection_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
) -> Result<ExecResult, DriverError> {
    let inferred_text_types = if needs_text_type_inference(params) {
        describe_query_parameters(connection, sql, params)
            .await?
            .inferred_text_types
    } else {
        Vec::new()
    };
    let query = bind_pg_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params, &inferred_text_types)?;
    let result = query.execute(&mut **connection).await.map_err(map_sqlx_error)?;
    Ok(ExecResult {
        rows_affected: result.rows_affected(),
    })
}

fn is_stale_type_cache_error(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Query {
            message,
            sqlstate: Some(sqlstate),
            ..
        } if sqlstate == "XX000" && message.starts_with("cache lookup failed for type ")
    )
}

pub(super) async fn stream_into_result(
    pool: &Pool<Postgres>,
    sql: &str,
    limit: usize,
) -> Result<QueryResult, DriverError> {
    let mut connection = pool.acquire().await.map_err(map_sqlx_error)?;
    let backend_pid = super::backend_pid(&mut connection).await?;
    let stop = Some(QueryStop { pool, backend_pid });
    let result = stream_into_result_once(&mut connection, sql, limit, stop).await;
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return stream_into_result_once(&mut connection, sql, limit, stop).await;
    }
    result
}

async fn stream_into_result_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    limit: usize,
    stop: Option<QueryStop<'_>>,
) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(sqlx::AssertSqlSafe(sql)).fetch(&mut **connection);
    let (mut result, mut type_infos, mut column_origins) = collect_query_rows(&mut stream, limit).await?;
    if result.truncated {
        stop_server_query(stop, &mut stream).await;
    }
    drop(stream);
    if result.columns.is_empty() && result.rows.is_empty() {
        let statement = connection
            .prepare(sqlx::AssertSqlSafe(sql).into_sql_str())
            .await
            .map_err(map_sqlx_error)?;
        result.columns = statement_columns(statement.columns());
        type_infos = statement_type_infos(statement.columns());
        column_origins = statement_column_origins(statement.columns());
    }
    refresh_enum_type_names(connection, &mut result.columns, &type_infos).await?;
    refresh_domain_column_names(connection, &mut result.columns, &column_origins).await?;
    Ok(result)
}

pub(super) fn statement_columns(columns: &[sqlx::postgres::PgColumn]) -> Vec<ColumnInfo> {
    columns
        .iter()
        .map(|column| ColumnInfo {
            name: column.name().to_string(),
            data_type: column.type_info().name().to_ascii_lowercase(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        })
        .collect()
}

pub(super) fn statement_type_infos(columns: &[sqlx::postgres::PgColumn]) -> Vec<PgTypeInfo> {
    columns.iter().map(|column| column.type_info().clone()).collect()
}

pub(super) fn statement_column_origins(columns: &[sqlx::postgres::PgColumn]) -> Vec<Option<(i64, i16)>> {
    columns
        .iter()
        .map(|column| Some((i64::from(column.relation_id()?.0), column.relation_attribute_no()?)))
        .collect()
}

async fn refresh_domain_column_names(
    connection: &mut PoolConnection<Postgres>,
    columns: &mut [ColumnInfo],
    origins: &[Option<(i64, i16)>],
) -> Result<(), DriverError> {
    if !origins.iter().any(Option::is_some) {
        return Ok(());
    }
    let relation_ids: Vec<_> = origins
        .iter()
        .map(|origin| origin.map(|(relation_id, _)| relation_id))
        .collect();
    let attribute_numbers: Vec<_> = origins
        .iter()
        .map(|origin| origin.map(|(_, attribute_no)| attribute_no))
        .collect();
    let rows = sqlx::query(
        "SELECT origin.ordinality - 1, pg_catalog.format_type(attribute.atttypid, NULL), \
                namespace.nspname, declared_type.typname \
         FROM unnest($1::bigint[], $2::smallint[]) WITH ORDINALITY \
              AS origin(relation_id, attribute_number, ordinality) \
         JOIN pg_catalog.pg_attribute AS attribute \
           ON attribute.attrelid::bigint = origin.relation_id \
          AND attribute.attnum = origin.attribute_number \
         JOIN pg_catalog.pg_type AS declared_type ON declared_type.oid = attribute.atttypid \
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = declared_type.typnamespace \
         WHERE declared_type.typtype = 'd'",
    )
    .bind(&relation_ids)
    .bind(&attribute_numbers)
    .fetch_all(&mut **connection)
    .await
    .map_err(map_sqlx_error)?;
    for row in rows {
        let index: i64 = row.try_get(0).map_err(map_sqlx_error)?;
        let name: String = row.try_get(1).map_err(map_sqlx_error)?;
        let schema: String = row.try_get(2).map_err(map_sqlx_error)?;
        let type_name: String = row.try_get(3).map_err(map_sqlx_error)?;
        if let Ok(index) = usize::try_from(index)
            && let Some(column) = columns.get_mut(index)
        {
            column.data_type = name;
            column.domain_type = Some(QualifiedTypeName {
                schema,
                name: type_name,
            });
        }
    }
    Ok(())
}

fn has_enum_leaf(type_info: &PgTypeInfo) -> bool {
    match type_info.kind() {
        PgTypeKind::Enum(_) => true,
        PgTypeKind::Array(element) | PgTypeKind::Domain(element) => has_enum_leaf(element),
        _ => false,
    }
}

async fn refresh_enum_type_names(
    connection: &mut PoolConnection<Postgres>,
    columns: &mut [ColumnInfo],
    type_infos: &[PgTypeInfo],
) -> Result<(), DriverError> {
    let type_oids: Vec<i64> = type_infos
        .iter()
        .filter(|type_info| has_enum_leaf(type_info))
        .filter_map(|type_info| type_info.oid().map(|oid| i64::from(oid.0)))
        .collect();
    if type_oids.is_empty() {
        return Ok(());
    }

    let rows = sqlx::query(
        "SELECT type.oid::bigint, pg_catalog.format_type(type.oid, NULL) \
         FROM pg_catalog.pg_type AS type \
         WHERE type.oid IN (SELECT unnest($1::bigint[])::oid)",
    )
    .bind(&type_oids)
    .fetch_all(&mut **connection)
    .await
    .map_err(map_sqlx_error)?;
    let mut names = HashMap::with_capacity(rows.len());
    for row in rows {
        let oid: i64 = row.try_get(0).map_err(map_sqlx_error)?;
        let name: String = row.try_get(1).map_err(map_sqlx_error)?;
        names.insert(oid, name);
    }

    for (column, type_info) in iter::zip(columns, type_infos) {
        if has_enum_leaf(type_info)
            && let Some(oid) = type_info.oid().map(|oid| i64::from(oid.0))
            && let Some(name) = names.get(&oid)
        {
            column.data_type.clone_from(name);
        }
    }
    Ok(())
}

async fn collect_query_rows<S>(
    stream: &mut S,
    limit: usize,
) -> Result<(QueryResult, Vec<PgTypeInfo>, Vec<Option<(i64, i16)>>), DriverError>
where
    S: futures::Stream<Item = Result<PgRow, sqlx::Error>> + Unpin,
{
    let mut columns = Vec::new();
    let mut type_infos = Vec::new();
    let mut column_origins = Vec::new();
    let mut type_names = Vec::new();
    let mut rows = Vec::new();
    let mut budget = QueryResultBudget::default();
    let mut truncated = false;
    while let Some(row_result) = stream.next().await {
        let row = row_result.map_err(map_sqlx_error)?;
        if rows.len() >= limit {
            truncated = true;
            break;
        }
        if rows.is_empty() {
            let metadata = stream_column_metadata(row.columns());
            columns = metadata.columns;
            type_infos = metadata.type_infos;
            column_origins = metadata.column_origins;
            type_names = metadata.type_names;
        }
        // Decode while streaming so the wire rows and the final Value matrix
        // do not both occupy memory for the entire result.
        let values = type_names
            .iter()
            .enumerate()
            .map(|(index, type_name)| extract_value(&row, index, type_name))
            .collect::<Result<Vec<_>, _>>()?;
        if !budget.admit(&values) {
            truncated = true;
            break;
        }
        rows.push(values);
    }
    Ok((
        QueryResult {
            columns,
            rows,
            truncated,
        },
        type_infos,
        column_origins,
    ))
}

struct PgColumnMetadata {
    columns: Vec<ColumnInfo>,
    type_infos: Vec<PgTypeInfo>,
    column_origins: Vec<Option<(i64, i16)>>,
    type_names: Vec<String>,
}

fn stream_column_metadata(pg_columns: &[sqlx::postgres::PgColumn]) -> PgColumnMetadata {
    let type_infos = statement_type_infos(pg_columns);
    let column_origins = statement_column_origins(pg_columns);
    let type_names = pg_columns
        .iter()
        .map(|column| column.type_info().name().to_ascii_uppercase())
        .collect();
    let columns = pg_columns
        .iter()
        .map(|column| ColumnInfo {
            name: column.name().to_string(),
            data_type: column.type_info().name().to_string(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        })
        .collect();
    PgColumnMetadata {
        columns,
        type_infos,
        column_origins,
        type_names,
    }
}

fn extract_value(row: &PgRow, idx: usize, type_name: &str) -> Result<Value, DriverError> {
    let raw = row.try_get_raw(idx).map_err(map_sqlx_error)?;
    if raw.is_null() {
        return Ok(Value::Null);
    }
    if matches!(raw.type_info().kind(), sqlx::postgres::PgTypeKind::Enum(_)) {
        return Ok(extract_enum_value(&raw, idx, type_name));
    }
    if matches!(raw.type_info().kind(), sqlx::postgres::PgTypeKind::Array(_)) {
        return Ok(array::decode(&raw).unwrap_or_else(|| undecodable(idx, type_name)));
    }
    if type_name == "NUMERIC" {
        let value = match raw.format() {
            sqlx::postgres::PgValueFormat::Binary => raw.as_bytes().ok().and_then(numeric::decode_binary),
            sqlx::postgres::PgValueFormat::Text => raw.as_str().ok().and_then(numeric::decode_text),
        };
        return Ok(value.unwrap_or_else(|| undecodable(idx, type_name)));
    }
    if raw.format() == sqlx::postgres::PgValueFormat::Binary {
        if matches!(type_name, "TIME" | "TIMETZ") {
            return Ok(raw
                .as_bytes()
                .ok()
                .and_then(|bytes| temporal::decode_time(bytes, type_name == "TIMETZ"))
                .unwrap_or_else(|| undecodable(idx, type_name)));
        }
        if matches!(type_name, "DATE" | "TIMESTAMP" | "TIMESTAMPTZ") {
            return Ok(raw
                .as_bytes()
                .ok()
                .and_then(|bytes| temporal::decode_temporal(bytes, type_name))
                .unwrap_or_else(|| undecodable(idx, type_name)));
        }
        if let Some(text) = raw
            .as_bytes()
            .ok()
            .and_then(|bytes| decode::decode_pg_binary_text(type_name, bytes))
        {
            return Ok(Value::Text(text));
        }
    }
    let decoded = match type_name {
        "BOOL" => row.try_get::<bool, _>(idx).map(Value::Bool),
        "INT2" => row.try_get::<i16, _>(idx).map(|v| Value::Int(v as i64)),
        "INT4" => row.try_get::<i32, _>(idx).map(|v| Value::Int(v as i64)),
        "INT8" => row.try_get::<i64, _>(idx).map(Value::Int),
        "FLOAT4" => row.try_get::<f32, _>(idx).map(|v| Value::Float(v as f64)),
        "FLOAT8" => row.try_get::<f64, _>(idx).map(Value::Float),
        "DATE" => row.try_get::<chrono::NaiveDate, _>(idx).map(Value::Date),
        "TIME" => row.try_get::<chrono::NaiveTime, _>(idx).map(Value::Time),
        "TIMESTAMP" => row.try_get::<chrono::NaiveDateTime, _>(idx).map(Value::DateTime),
        "TIMESTAMPTZ" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz),
        "UUID" => row.try_get::<uuid::Uuid, _>(idx).map(Value::Uuid),
        "JSON" | "JSONB" => row.try_get::<serde_json::Value, _>(idx).map(Value::Json),
        "BYTEA" => row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes),
        _ => row.try_get::<String, _>(idx).map(Value::Text),
    };
    Ok(decoded.unwrap_or_else(|_| undecodable(idx, type_name)))
}

fn extract_enum_value(raw: &sqlx::postgres::PgValueRef<'_>, idx: usize, type_name: &str) -> Value {
    let label = match raw.format() {
        sqlx::postgres::PgValueFormat::Binary => raw.as_bytes().ok().and_then(|bytes| std::str::from_utf8(bytes).ok()),
        sqlx::postgres::PgValueFormat::Text => raw.as_str().ok(),
    };
    label
        .map(|value| Value::Text(value.to_owned()))
        .unwrap_or_else(|| undecodable(idx, type_name))
}

pub(super) fn undecodable(idx: usize, type_name: &str) -> Value {
    tracing::warn!(
        column_index = idx + 1,
        type_name,
        "postgres column value could not be decoded; showing it as undecodable"
    );
    Value::Undecodable(type_name.to_string())
}

#[cfg(test)]
mod tests {
    use super::has_enum_leaf;
    use sqlx::{Postgres, Type};

    #[test]
    fn value_contract_enum_leaf_detection_skips_builtin_scalar_types() {
        let int4 = <i32 as Type<Postgres>>::type_info();
        assert!(!has_enum_leaf(&int4));
    }
}
