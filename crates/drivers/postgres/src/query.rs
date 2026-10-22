use std::{collections::HashMap, iter};

use futures::stream::StreamExt;
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgCancelToken, PgRow, PgTypeInfo, PgTypeKind};
use sqlx::{Column, Connection, Executor, Pool, Postgres, Row, SqlSafeStr, Statement, TypeInfo, ValueRef};
use tablepro_core::{
    ColumnInfo, DriverError, ExecResult, MAX_QUERY_ROWS, QualifiedTypeName, QueryResult, QueryResultBudget, Value,
};

use super::params::{bind_pg_params, describe_query_parameters, needs_text_type_inference, pg_parameter_type_infos};
use super::{array, decode, map_sqlx_error, numeric, temporal};

#[derive(Clone)]
pub(super) struct QueryStop {
    pub cancel_token: PgCancelToken,
}

async fn stop_server_query<S>(stop: Option<QueryStop>, stream: &mut S)
where
    S: futures::Stream<Item = Result<PgRow, sqlx::Error>> + Unpin,
{
    let Some(stop) = stop else {
        return;
    };
    if let Err(error) = super::request_cancellation(stop.cancel_token).await {
        tracing::warn!(%error, "the server was not told to stop a capped query");
        return;
    }
    while stream.next().await.is_some() {}
}

pub(super) async fn query_connection(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
    stop: Option<QueryStop>,
) -> Result<QueryResult, DriverError> {
    let result = query_attempt(connection, sql, params, stop.clone()).await;
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return query_connection_once(connection, sql, params, stop).await;
    }
    result.map_err(QueryFailure::into_driver)
}

pub(super) async fn query_connection_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
    stop: Option<QueryStop>,
) -> Result<QueryResult, DriverError> {
    query_attempt(connection, sql, params, stop)
        .await
        .map_err(QueryFailure::into_driver)
}

async fn query_attempt(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
    stop: Option<QueryStop>,
) -> Result<QueryResult, QueryFailure> {
    let description = if needs_text_type_inference(params) {
        Some(describe_query_parameters(connection, sql, params).await?)
    } else {
        None
    };
    let inferred_text_types = description
        .as_ref()
        .map_or(&[][..], |description| description.inferred_text_types.as_slice());
    let needs_text_results = match description.as_ref() {
        Some(description) => description.column_type_infos.iter().any(requires_server_text_result),
        None => {
            let parameter_types = pg_parameter_type_infos(params);
            let statement = connection
                .prepare_with(sqlx::AssertSqlSafe(sql).into_sql_str(), &parameter_types)
                .await?;
            statement
                .columns()
                .iter()
                .any(|column| requires_server_text_result(column.type_info()))
        }
    };
    if needs_text_results {
        connection.set_next_query_result_format(sql, sqlx::postgres::PgValueFormat::Text);
    }
    let mut stream =
        bind_pg_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params, inferred_text_types)?.fetch(&mut **connection);
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
    let result = execute_attempt(connection, sql, params).await;
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return execute_connection_once(connection, sql, params).await;
    }
    result.map_err(QueryFailure::into_driver)
}

pub(super) async fn execute_connection_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
) -> Result<ExecResult, DriverError> {
    execute_attempt(connection, sql, params)
        .await
        .map_err(QueryFailure::into_driver)
}

async fn execute_attempt(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    params: &[Value],
) -> Result<ExecResult, QueryFailure> {
    let inferred_text_types = if needs_text_type_inference(params) {
        describe_query_parameters(connection, sql, params)
            .await?
            .inferred_text_types
    } else {
        Vec::new()
    };
    let query = bind_pg_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params, &inferred_text_types)?;
    let result = query.execute(&mut **connection).await?;
    Ok(ExecResult {
        rows_affected: result.rows_affected(),
    })
}

pub(super) enum QueryFailure {
    Driver(DriverError),
    Sqlx(sqlx::Error),
}

impl QueryFailure {
    pub(super) fn into_driver(self) -> DriverError {
        match self {
            Self::Driver(error) => error,
            Self::Sqlx(error) => map_sqlx_error(error),
        }
    }
}

impl From<DriverError> for QueryFailure {
    fn from(error: DriverError) -> Self {
        Self::Driver(error)
    }
}

impl From<sqlx::Error> for QueryFailure {
    fn from(error: sqlx::Error) -> Self {
        Self::Sqlx(error)
    }
}

fn is_stale_type_cache_error(error: &QueryFailure) -> bool {
    let QueryFailure::Sqlx(sqlx::Error::Database(error)) = error else {
        return false;
    };
    let Some(error) = error.try_downcast_ref::<sqlx::postgres::PgDatabaseError>() else {
        return false;
    };
    if error.r#where().is_some() {
        return false;
    }
    matches!(
        (error.code(), error.file(), error.routine()),
        ("0A000", Some("plancache.c"), Some("RevalidateCachedQuery"))
            | (
                "XX000",
                Some("lsyscache.c"),
                Some("getTypeInputInfo" | "getTypeBinaryInputInfo")
            )
    )
}

pub(super) async fn stream_into_result(
    pool: &Pool<Postgres>,
    sql: &str,
    limit: usize,
) -> Result<QueryResult, DriverError> {
    let mut connection = pool.acquire().await.map_err(map_sqlx_error)?;
    let stop = Some(QueryStop {
        cancel_token: connection.cancel_token(),
    });
    let result = stream_into_result_once(&mut connection, sql, limit, stop.clone()).await;
    if result.as_ref().is_err_and(is_stale_type_cache_error) {
        connection.clear_cached_statements().await.map_err(map_sqlx_error)?;
        return stream_into_result_once(&mut connection, sql, limit, stop.clone())
            .await
            .map_err(QueryFailure::into_driver);
    }
    result.map_err(QueryFailure::into_driver)
}

async fn stream_into_result_once(
    connection: &mut PoolConnection<Postgres>,
    sql: &str,
    limit: usize,
    stop: Option<QueryStop>,
) -> Result<QueryResult, QueryFailure> {
    let statement = connection.prepare(sqlx::AssertSqlSafe(sql).into_sql_str()).await?;
    if statement
        .columns()
        .iter()
        .any(|column| requires_server_text_result(column.type_info()))
    {
        connection.set_next_query_result_format(sql, sqlx::postgres::PgValueFormat::Text);
    }
    drop(statement);
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
) -> Result<(QueryResult, Vec<PgTypeInfo>, Vec<Option<(i64, i16)>>), QueryFailure>
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
        let row = row_result.map_err(|error| {
            if rows.is_empty() {
                QueryFailure::Sqlx(error)
            } else {
                QueryFailure::Driver(map_sqlx_error(error))
            }
        })?;
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
        let payload_bytes = pg_row_payload_bytes(&row).unwrap_or(usize::MAX);
        let Some(values) = budget.decode_and_admit_row(row.len(), payload_bytes, || {
            type_names
                .iter()
                .enumerate()
                .map(|(index, type_name)| extract_value(&row, index, type_name))
                .collect::<Result<Vec<_>, _>>()
        })?
        else {
            truncated = true;
            break;
        };
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

fn pg_row_payload_bytes(row: &PgRow) -> Option<usize> {
    (0..row.len()).try_fold(0usize, |total, index| {
        let value = row.try_get_raw(index).ok()?;
        if value.is_null() {
            return Some(total);
        }
        Some(total.saturating_add(value.as_bytes().ok()?.len()))
    })
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
    if type_name == "VOID" {
        return Ok(Value::Text(String::new()));
    }
    Ok(extract_non_null_value(row, idx, type_name, &raw))
}

fn extract_non_null_value(row: &PgRow, idx: usize, type_name: &str, raw: &sqlx::postgres::PgValueRef<'_>) -> Value {
    if matches!(raw.type_info().kind(), sqlx::postgres::PgTypeKind::Enum(_)) {
        return extract_enum_value(raw, idx, type_name);
    }
    if matches!(raw.type_info().kind(), sqlx::postgres::PgTypeKind::Array(_)) {
        return array::decode(raw).unwrap_or_else(|| undecodable(idx, type_name));
    }
    if type_name == "NUMERIC" {
        let value = match raw.format() {
            sqlx::postgres::PgValueFormat::Binary => raw.as_bytes().ok().and_then(numeric::decode_binary),
            sqlx::postgres::PgValueFormat::Text => raw.as_str().ok().and_then(numeric::decode_text),
        };
        return value.unwrap_or_else(|| undecodable(idx, type_name));
    }
    if type_name == "JSON" {
        return extract_json_text(raw, idx, type_name);
    }
    if raw.format() == sqlx::postgres::PgValueFormat::Binary {
        if matches!(type_name, "TIME" | "TIMETZ") {
            return raw
                .as_bytes()
                .ok()
                .and_then(|bytes| temporal::decode_time(bytes, type_name == "TIMETZ"))
                .unwrap_or_else(|| undecodable(idx, type_name));
        }
        if matches!(type_name, "DATE" | "TIMESTAMP" | "TIMESTAMPTZ") {
            return raw
                .as_bytes()
                .ok()
                .and_then(|bytes| temporal::decode_temporal(bytes, type_name))
                .unwrap_or_else(|| undecodable(idx, type_name));
        }
        if let Some(text) = raw
            .as_bytes()
            .ok()
            .and_then(|bytes| decode::decode_pg_binary_text(type_name, bytes))
        {
            return Value::Text(text);
        }
    }
    let decoded = match type_name {
        "BOOL" => row.try_get::<bool, _>(idx).map(Value::Bool),
        "INT2" => row.try_get::<i16, _>(idx).map(|v| Value::Int(v as i64)),
        "INT4" => row.try_get::<i32, _>(idx).map(|v| Value::Int(v as i64)),
        "INT8" => row.try_get::<i64, _>(idx).map(Value::Int),
        "FLOAT4" => row
            .try_get::<f32, _>(idx)
            .map(|v| Value::Float(tablepro_core::single_precision_as_f64(v))),
        "FLOAT8" => row.try_get::<f64, _>(idx).map(Value::Float),
        "DATE" => row.try_get::<chrono::NaiveDate, _>(idx).map(Value::Date),
        "TIME" => row.try_get::<chrono::NaiveTime, _>(idx).map(Value::Time),
        "TIMESTAMP" => row.try_get::<chrono::NaiveDateTime, _>(idx).map(Value::DateTime),
        "TIMESTAMPTZ" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz),
        "UUID" => row.try_get::<uuid::Uuid, _>(idx).map(Value::Uuid),
        "JSONB" => row.try_get::<serde_json::Value, _>(idx).map(Value::Json),
        "BYTEA" => row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes),
        _ => extract_fallback_text(row, idx, raw),
    };
    decoded.unwrap_or_else(|_| undecodable(idx, type_name))
}

fn extract_fallback_text(row: &PgRow, idx: usize, raw: &sqlx::postgres::PgValueRef<'_>) -> Result<Value, sqlx::Error> {
    if raw.format() == sqlx::postgres::PgValueFormat::Text {
        return raw
            .as_str()
            .map(|value| Value::Text(value.into()))
            .map_err(sqlx::Error::Decode);
    }
    row.try_get::<String, _>(idx).map(Value::Text)
}

fn extract_json_text(raw: &sqlx::postgres::PgValueRef<'_>, idx: usize, type_name: &str) -> Value {
    raw.as_str()
        .map(|value| Value::JsonText(value.to_owned()))
        .unwrap_or_else(|_| undecodable(idx, type_name))
}

fn requires_server_text_result(type_info: &PgTypeInfo) -> bool {
    let name = type_info.name().trim_matches('"');
    [
        "CHAR", "HSTORE", "LTREE", "OID", "RECORD", "REGCLASS", "TSVECTOR", "XML",
    ]
    .iter()
    .any(|candidate| name.eq_ignore_ascii_case(candidate))
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
