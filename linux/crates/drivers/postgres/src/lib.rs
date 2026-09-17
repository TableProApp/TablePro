use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgRow};
use sqlx::{AssertSqlSafe, Column, Pool, Postgres, Row, TypeInfo, ValueRef};

use futures::stream::StreamExt;

use tablepro_core::column::{
    CatalogType, ColumnDefault, ColumnType, ReadForm, ResultColumn, SqlExpression, SqlTypeExpr, classify_type_name,
    has_dynamic_storage,
};
use tablepro_core::value::{BitString, JsonText, OffsetTimestamp, SqlInterval, SqlTime, Temporal, TimeWithOffset};
use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    LossPhase, MAX_QUERY_ROWS, NetworkEndpoint, QueryResult, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TableInfo,
    TimeoutPhase, TlsFailure, TransportError, Value,
};

pub struct PgDriver;

#[async_trait]
impl DatabaseDriver for PgDriver {
    fn id(&self) -> &'static str {
        "postgres"
    }

    fn display_name(&self) -> &'static str {
        "PostgreSQL"
    }

    fn default_port(&self) -> u16 {
        5432
    }

    fn ddl_is_transactional(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let pg_opts = PgConnectOptions::new()
            .host(&opts.host)
            .port(opts.port)
            .database(&opts.database)
            .username(&opts.username)
            .password(opts.password.expose_secret())
            .ssl_mode(if opts.use_tls {
                sqlx::postgres::PgSslMode::Require
            } else {
                sqlx::postgres::PgSslMode::Disable
            });
        let endpoint = NetworkEndpoint::new(&opts.host, opts.port)?;
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(pg_opts)
            .await
            .map_err(|error| map_connect_error(error, &endpoint))?;
        Ok(Box::new(PgConnection { pool }))
    }
}

struct PgConnection {
    pool: Pool<Postgres>,
}

#[async_trait]
impl Connection for PgConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT schemaname, tablename
             FROM pg_tables
             WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
             ORDER BY schemaname, tablename",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| TableInfo {
                schema: Some(r.get::<String, _>(0)),
                name: r.get::<String, _>(1),
            })
            .collect())
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        // Source schema metadata from pg_catalog rather than
        // information_schema:
        //   - pg_attribute.attgenerated ('s' for STORED, '' otherwise)
        //     is the canonical generated-column flag. The
        //     information_schema.is_generated text column is brittle
        //     across PG versions.
        //   - pg_attribute.attidentity ('a' / 'd' for ALWAYS / BY
        //     DEFAULT identity, '' otherwise) authoritatively flags
        //     identity columns.
        //   - format_type() returns the user-facing type name including
        //     length / precision (e.g. "character varying(255)") which
        //     matches what the user wrote in CREATE TABLE.
        //   - pg_get_expr() returns the default expression text.
        let rows = sqlx::query(
            "SELECT
                a.attname,
                pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
                NOT a.attnotnull AS nullable,
                EXISTS (
                    SELECT 1 FROM pg_catalog.pg_constraint c
                    WHERE c.conrelid = a.attrelid
                      AND c.contype = 'p'
                      AND a.attnum = ANY(c.conkey)
                ) AS is_pk,
                pg_catalog.pg_get_expr(d.adbin, d.adrelid) AS default_value,
                a.attidentity <> '' AS is_identity,
                a.attgenerated <> '' AS is_generated,
                pg_catalog.col_description(a.attrelid, a.attnum) AS comment
             FROM pg_catalog.pg_attribute a
             JOIN pg_catalog.pg_class t ON a.attrelid = t.oid
             JOIN pg_catalog.pg_namespace n ON t.relnamespace = n.oid
             LEFT JOIN pg_catalog.pg_attrdef d
                 ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             WHERE n.nspname = COALESCE($2, current_schema())
               AND t.relname = $1
               AND a.attnum > 0
               AND NOT a.attisdropped
             ORDER BY a.attnum",
        )
        .bind(table)
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let raw_default: Option<String> = r.try_get::<Option<String>, _>(4).unwrap_or(None);
                let is_identity = r.try_get::<bool, _>(5).unwrap_or(false);
                let is_generated = r.try_get::<bool, _>(6).unwrap_or(false);
                let comment = r.try_get::<Option<String>, _>(7).unwrap_or(None);
                // SERIAL / BIGSERIAL columns aren't IDENTITY in PG's
                // catalog terms but have a `nextval(...)` default; treat
                // them as auto-increment for the inline-insert UI.
                let is_serial = raw_default
                    .as_deref()
                    .map(|d| d.starts_with("nextval("))
                    .unwrap_or(false);
                // For identity / serial columns the default expression
                // is internal sequence machinery — suppress so the UI
                // doesn't leak implementation details. Otherwise
                // normalise the expression for display.
                let default_value = if is_identity || is_serial {
                    None
                } else {
                    raw_default.map(normalize_pg_default)
                };
                let type_name = r.get::<String, _>(1);
                ColumnInfo {
                    name: r.get::<String, _>(0),
                    column_type: column_type_of(&type_name),
                    nullable: r.get::<bool, _>(2),
                    primary_key: r.get::<bool, _>(3),
                    is_auto_increment: is_identity || is_serial,
                    is_generated,
                    default: match default_value {
                        Some(text) => ColumnDefault::Expression(SqlExpression::from_catalog_text(text)),
                        None => ColumnDefault::None,
                    },
                    comment,
                }
            })
            .collect())
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let sql = format!(
            "SELECT * FROM {} OFFSET {offset} LIMIT {limit}",
            qualified(schema, table)
        );
        stream_into_result(&self.pool, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        stream_into_result(&self.pool, sql, MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let q = bind_pg_params(sqlx::query(AssertSqlSafe(sql)), params);
        let mut stream = q.fetch(&self.pool);
        let mut collected: Vec<PgRow> = Vec::new();
        let mut truncated = false;
        while let Some(row_result) = stream.next().await {
            let row = row_result.map_err(map_sqlx_error)?;
            if collected.len() >= MAX_QUERY_ROWS {
                truncated = true;
                break;
            }
            collected.push(row);
        }
        if collected.is_empty() {
            return Ok(QueryResult::empty().truncated(truncated));
        }
        let columns: Vec<ResultColumn> = collected[0]
            .columns()
            .iter()
            .map(|c| ResultColumn::new(c.name(), column_type_of(c.type_info().name())))
            .collect();
        let width = columns.len();
        let data: Vec<Vec<Value>> = collected
            .iter()
            .map(|r| (0..width).map(|i| extract_value(r, i)).collect())
            .collect();
        Ok(QueryResult::new(columns, data).truncated(truncated))
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let res = sqlx::query(AssertSqlSafe(sql))
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let q = bind_pg_params(sqlx::query(AssertSqlSafe(sql)), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_pg_params(sqlx::query(AssertSqlSafe(sql.as_str())), params);
            match q.execute(&mut *tx).await {
                Ok(res) => affected.push(res.rows_affected()),
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(DriverError::RolledBack {
                        statement_index: idx,
                        source: Box::new(map_sqlx_error(e)),
                    });
                }
            }
        }
        tx.commit().await.map_err(map_sqlx_error)?;
        Ok(affected)
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // pg_index + pg_class + pg_attribute join. `array_agg ORDER BY
        // ordinality` keeps the column order deterministic; pg_index
        // stores `indkey` as an int2vector positional reference so we
        // unnest with `WITH ORDINALITY` to capture position.
        let rows = sqlx::query(
            "SELECT
                i.relname AS index_name,
                ix.indisunique,
                ix.indisprimary,
                array_agg(a.attname ORDER BY k.ordinality) AS columns
            FROM pg_catalog.pg_class t
            JOIN pg_catalog.pg_namespace n ON t.relnamespace = n.oid
            JOIN pg_catalog.pg_index ix ON ix.indrelid = t.oid
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ordinality) ON true
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
            WHERE n.nspname = COALESCE($2, current_schema())
              AND t.relname = $1
              AND a.attnum > 0
            GROUP BY i.relname, ix.indisunique, ix.indisprimary
            ORDER BY i.relname",
        )
        .bind(table)
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| IndexInfo {
                name: r.get::<String, _>(0),
                unique: r.get::<bool, _>(1),
                primary: r.get::<bool, _>(2),
                columns: r.get::<Vec<String>, _>(3),
            })
            .collect())
    }

    async fn fetch_foreign_keys(&self, schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        // pg_constraint with contype = 'f'. confkey arrays are parallel
        // to conkey via ordinality; the LATERAL join pairs them so the
        // FK column ↔ referenced column mapping survives composite
        // FKs. confdeltype / confupdtype are single chars normalised
        // to canonical SQL keyword strings.
        let rows = sqlx::query(
            "SELECT
                c.conname AS fk_name,
                array_agg(a.attname ORDER BY kf.ordinality) AS columns,
                fn_class.relname AS ref_table,
                fn_ns.nspname AS ref_schema,
                array_agg(fa.attname ORDER BY kf.ordinality) AS ref_columns,
                c.confdeltype,
                c.confupdtype
            FROM pg_catalog.pg_constraint c
            JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_catalog.pg_class fn_class ON fn_class.oid = c.confrelid
            JOIN pg_catalog.pg_namespace fn_ns ON fn_ns.oid = fn_class.relnamespace
            JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS kf(attnum, ordinality) ON true
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = kf.attnum
            JOIN LATERAL unnest(c.confkey) WITH ORDINALITY AS kfr(attnum, ordinality)
                ON kfr.ordinality = kf.ordinality
            JOIN pg_catalog.pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = kfr.attnum
            WHERE c.contype = 'f'
              AND n.nspname = COALESCE($2, current_schema())
              AND t.relname = $1
            GROUP BY c.conname, fn_class.relname, fn_ns.nspname, c.confdeltype, c.confupdtype
            ORDER BY c.conname",
        )
        .bind(table)
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| ForeignKeyInfo {
                name: r.get::<String, _>(0),
                columns: r.get::<Vec<String>, _>(1),
                ref_table: r.get::<String, _>(2),
                ref_schema: r.try_get::<Option<String>, _>(3).unwrap_or(None),
                ref_columns: r.get::<Vec<String>, _>(4),
                on_delete: pg_action_char_to_keyword(r.try_get::<String, _>(5).ok().as_deref().unwrap_or("a")),
                on_update: pg_action_char_to_keyword(r.try_get::<String, _>(6).ok().as_deref().unwrap_or("a")),
            })
            .collect())
    }

    async fn ping(&self) -> Result<(), DriverError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        Ok(())
    }
}

async fn stream_into_result(pool: &Pool<Postgres>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(AssertSqlSafe(sql)).fetch(pool);
    let mut collected: Vec<PgRow> = Vec::new();
    let mut truncated = false;
    while let Some(row_result) = stream.next().await {
        let row = row_result.map_err(map_sqlx_error)?;
        if collected.len() >= limit {
            truncated = true;
            break;
        }
        collected.push(row);
    }
    if collected.is_empty() {
        return Ok(QueryResult::empty().truncated(truncated));
    }
    let columns: Vec<ResultColumn> = collected[0]
        .columns()
        .iter()
        .map(|c| ResultColumn::new(c.name(), column_type_of(c.type_info().name())))
        .collect();
    let width = columns.len();
    let data: Vec<Vec<Value>> = collected
        .iter()
        .map(|r| (0..width).map(|i| extract_value(r, i)).collect())
        .collect();
    Ok(QueryResult::new(columns, data).truncated(truncated))
}

fn extract_value(row: &PgRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    let name = type_name.as_str();
    match name {
        "BOOL" => decode(row, idx, name, |v: bool| Some(Value::Bool(v))),
        "INT2" => decode(row, idx, name, |v: i16| Some(Value::Int(i64::from(v)))),
        "INT4" => decode(row, idx, name, |v: i32| Some(Value::Int(i64::from(v)))),
        "INT8" => decode(row, idx, name, |v: i64| Some(Value::Int(v))),
        // A real is kept at its own width: widening it to f64 and back
        // does not round-trip.
        "FLOAT4" => decode(row, idx, name, |v: f32| Some(Value::Float32(v))),
        "FLOAT8" => decode(row, idx, name, |v: f64| Some(Value::Float64(v))),
        // NUMERIC arrives in the binary form, so it decodes through the
        // wire type and is reparsed from its own text at full scale.
        "NUMERIC" => numeric_cell(row, idx, name),
        "DATE" => decode(row, idx, name, |v: chrono::NaiveDate| {
            Some(Value::Date(Temporal::Finite(v)))
        }),
        "TIME" => decode(row, idx, name, |v: chrono::NaiveTime| {
            Some(Value::Time(SqlTime::from_time_of_day(v)))
        }),
        "TIMETZ" => decode(
            row,
            idx,
            name,
            |v: sqlx::postgres::types::PgTimeTz<chrono::NaiveTime, chrono::FixedOffset>| {
                Some(Value::TimeTz(TimeWithOffset {
                    time: SqlTime::from_time_of_day(v.time),
                    offset: v.offset,
                }))
            },
        ),
        "TIMESTAMP" => decode(row, idx, name, |v: chrono::NaiveDateTime| {
            Some(Value::Timestamp(Temporal::Finite(v)))
        }),
        "TIMESTAMPTZ" => decode(row, idx, name, |v: chrono::DateTime<chrono::Utc>| {
            Some(Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                v.fixed_offset(),
            ))))
        }),
        "UUID" => decode(row, idx, name, |v: uuid::Uuid| Some(Value::Uuid(v))),
        "JSON" | "JSONB" => json_cell(row, idx, name),
        "BYTEA" => decode(row, idx, name, |v: Vec<u8>| Some(Value::Bytes(v))),
        "BIT" | "VARBIT" => decode(row, idx, name, |v: sqlx::types::BitVec| bits_value(&v)),
        "INTERVAL" => decode(row, idx, name, |v: sqlx::postgres::types::PgInterval| {
            Some(Value::Interval(SqlInterval {
                months: v.months,
                days: v.days,
                microseconds: v.microseconds,
            }))
        }),
        _ => decode(row, idx, name, |v: String| Some(Value::Text(v))),
    }
}

/// Read one cell, keeping three outcomes apart: a real NULL, a value
/// the driver read, and one it could not read. A type with no decoder
/// says so rather than reading as an empty cell the user would take
/// for a NULL.
fn decode<'r, T, F>(row: &'r PgRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    T: sqlx::Decode<'r, Postgres> + sqlx::Type<Postgres>,
    F: FnOnce(T) -> Option<Value>,
{
    match row.try_get::<Option<T>, _>(idx) {
        Ok(Some(raw)) => into_value(raw).unwrap_or_else(|| undecodable(type_name)),
        Ok(None) => Value::Null,
        Err(_) => undecodable(type_name),
    }
}

/// Bind a positional parameter list to a sqlx Postgres query in the
/// same order as the `params` slice. Centralised here so
/// `execute_params` and `execute_in_transaction` produce identical
/// bindings without duplicating the variant match.
fn bind_pg_params<'q>(
    mut q: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments> {
    for p in params {
        q = match p {
            Value::Null => q.bind(Option::<&str>::None),
            Value::Bool(b) => q.bind(*b),
            Value::Int(i) => q.bind(*i),
            Value::Float32(f) => q.bind(*f),
            Value::Float64(f) => q.bind(*f),
            Value::Text(s) => q.bind(s.clone()),
            Value::Bytes(b) => q.bind(b.clone()),
            Value::Date(Temporal::Finite(d)) => q.bind(*d),
            Value::Timestamp(Temporal::Finite(t)) => q.bind(*t),
            Value::TimestampTz(Temporal::Finite(t)) => q.bind(t.to_datetime()),
            Value::Uuid(u) => q.bind(*u),
            // PostgreSQL refuses a text parameter where it wants a
            // numeric, so these bind as the wire type the column
            // expects rather than as their text form.
            Value::Decimal(d) => match to_pg_decimal(d) {
                Some(decimal) => q.bind(decimal),
                // Past what the wire type holds. Text reaches the
                // server, which refuses it with its own message,
                // rather than a quietly rounded number.
                None => q.bind(d.to_string()),
            },
            Value::Json(j) => match serde_json::from_str::<serde_json::Value>(j.as_str()) {
                Ok(json) => q.bind(json),
                Err(_) => q.bind(j.as_str().to_owned()),
            },
            Value::Time(t) => match t.to_time_of_day() {
                Some(time) => q.bind(time),
                None => q.bind(t.format(None)),
            },
            // Everything else is sent as text for the server to parse
            // from its own output form.
            other => match tablepro_core::export::value_to_text(other) {
                Some(text) => q.bind(text),
                None => q.bind(Option::<&str>::None),
            },
        };
    }
    q
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Normalize the `default_value` text returned by `pg_get_expr`.
/// PG appends an explicit type cast to typed literal defaults
/// (`'hi'::text`, `42::integer`, `'2024-01-01'::date`); strip the
/// trailing `::TYPE` cast for display so the value reads as the user
/// would type it. Then, if the result is a single-quoted string
/// literal, strip the outer quotes (matching the SQLite driver's
/// behaviour) so default values look the same across all engines.
/// Function-call defaults like `now()` and complex expressions are
/// returned unchanged.
fn normalize_pg_default(raw: String) -> String {
    let stripped = strip_pg_type_cast(&raw).unwrap_or(raw.as_str()).to_string();
    strip_outer_single_quotes(&stripped)
}

fn strip_pg_type_cast(raw: &str) -> Option<&str> {
    let idx = raw.rfind("::")?;
    let suffix = &raw[idx + 2..];
    if suffix.is_empty() {
        return None;
    }
    let is_type_name = suffix
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == ' ' || c == '(' || c == ')' || c == ',' || c == '_');
    if is_type_name { Some(&raw[..idx]) } else { None }
}

fn strip_outer_single_quotes(raw: &str) -> String {
    let bytes = raw.as_bytes();
    if bytes.len() >= 2 && bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\'' {
        // PG escapes embedded apostrophes by doubling, same as SQLite.
        return raw[1..raw.len() - 1].replace("''", "'");
    }
    raw.to_string()
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{}.{}", quote_ident(s), quote_ident(table)),
        None => quote_ident(table),
    }
}

/// Map `pg_constraint.confdeltype` / `confupdtype` single-char codes
/// to canonical SQL action keywords. Returns `None` for the default
/// "no action" so the FK builder can omit the redundant ON clause.
fn pg_action_char_to_keyword(code: &str) -> Option<String> {
    match code {
        "r" => Some("RESTRICT".into()),
        "c" => Some("CASCADE".into()),
        "n" => Some("SET NULL".into()),
        "d" => Some("SET DEFAULT".into()),
        // 'a' = NO ACTION is the default; surface as None so the
        // generated DDL stays clean.
        _ => None,
    }
}

/// A failure during connect, where an unreachable server is the
/// answer rather than a connection that was lost.
fn map_connect_error(err: sqlx::Error, endpoint: &NetworkEndpoint) -> DriverError {
    match err {
        sqlx::Error::Io(io) => DriverError::Transport(connect_transport_error(&io, endpoint)),
        sqlx::Error::PoolTimedOut => DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        }),
        other => map_sqlx_error(other),
    }
}

fn connect_transport_error(io: &std::io::Error, endpoint: &NetworkEndpoint) -> TransportError {
    match io.kind() {
        std::io::ErrorKind::ConnectionRefused => TransportError::Refused {
            endpoint: endpoint.clone(),
        },
        std::io::ErrorKind::TimedOut => TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        },
        _ => TransportError::Unreachable {
            endpoint: endpoint.clone(),
            detail: io.to_string(),
        },
    }
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    match err {
        sqlx::Error::Database(error) => match error.try_downcast_ref::<sqlx::postgres::PgDatabaseError>() {
            Some(pg) => server_error(pg),
            None => DriverError::server(error.message().to_owned()),
        },
        sqlx::Error::Io(io) => io_error(&io),
        sqlx::Error::Tls(error) => tls_error(error.as_ref()),
        // The pool's wait ends only when every connection is busy, so
        // it is the server having no room rather than a slow network.
        sqlx::Error::PoolTimedOut => DriverError::Busy,
        sqlx::Error::PoolClosed | sqlx::Error::WorkerCrashed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        sqlx::Error::ColumnDecode { index, source } => DriverError::Decode {
            column: index,
            detail: source.to_string(),
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// The SQLSTATEs that mean something the app acts on. Everything else
/// is the server's own answer, passed through with its diagnostics.
fn server_error(pg: &sqlx::postgres::PgDatabaseError) -> DriverError {
    let diagnostics = diagnostics_of(pg);
    match pg.code() {
        "28P01" | "28000" => DriverError::auth(Some(diagnostics)),
        "25006" => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        "57014" => DriverError::Cancelled,
        "55P03" => DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            server_cancelled: true,
        },
        "53300" => DriverError::Busy,
        _ => DriverError::reported(diagnostics),
    }
}

fn diagnostics_of(pg: &sqlx::postgres::PgDatabaseError) -> ServerDiagnostics {
    ServerDiagnostics {
        code: Some(ServerCode::SqlState(pg.code().to_owned())),
        severity: Some(format!("{:?}", pg.severity())),
        message: pg.message().to_owned(),
        detail: pg.detail().map(str::to_owned),
        hint: pg.hint().map(str::to_owned),
        position: match pg.position() {
            Some(sqlx::postgres::PgErrorPosition::Original(at)) => u32::try_from(at).ok(),
            _ => None,
        },
        where_context: pg.r#where().map(str::to_owned),
        schema: pg.schema().map(str::to_owned),
        table: pg.table().map(str::to_owned),
        column: pg.column().map(str::to_owned),
        constraint: pg.constraint().map(str::to_owned),
    }
}

/// An I/O failure on an open connection is the connection going away,
/// whatever the kind says.
fn io_error(_io: &std::io::Error) -> DriverError {
    DriverError::ConnectionLost {
        during: LossPhase::Statement,
    }
}

fn tls_error(error: &(dyn std::error::Error + 'static)) -> DriverError {
    let (failure, detail) =
        tablepro_net::tls::classify(error).unwrap_or_else(|| (TlsFailure::Other, error.to_string()));
    DriverError::Tls { failure, detail }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refused_connect_names_the_endpoint_it_tried() {
        let endpoint = NetworkEndpoint::new("db.internal", 5432).expect("an endpoint");
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));

        let mapped = map_connect_error(err, &endpoint);

        assert!(
            matches!(&mapped, DriverError::Transport(TransportError::Refused { endpoint: at }) if at == &endpoint),
            "got {mapped:?}"
        );
        assert_eq!(mapped.category(), tablepro_core::ErrorCategory::Network);
    }

    #[test]
    fn a_dropped_connection_mid_statement_is_not_a_refusal() {
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::BrokenPipe));

        let mapped = map_sqlx_error(err);

        assert!(
            matches!(
                mapped,
                DriverError::ConnectionLost {
                    during: LossPhase::Statement
                }
            ),
            "got {mapped:?}"
        );
    }

    #[test]
    fn a_full_server_is_busy_rather_than_broken() {
        assert!(matches!(map_sqlx_error(sqlx::Error::PoolTimedOut), DriverError::Busy));
    }

    #[test]
    fn driver_metadata() {
        let d = PgDriver;
        assert_eq!(d.id(), "postgres");
        assert_eq!(d.default_port(), 5432);
    }

    #[test]
    fn quote_ident_doubles_embedded_quotes() {
        assert_eq!(quote_ident("users"), "\"users\"");
        assert_eq!(quote_ident("My Table"), "\"My Table\"");
        assert_eq!(
            quote_ident("evil\"; DROP TABLE x; --"),
            "\"evil\"\"; DROP TABLE x; --\""
        );
    }

    #[test]
    fn normalize_pg_default_strips_type_cast_and_quotes() {
        assert_eq!(normalize_pg_default("'hi'::text".into()), "hi");
        assert_eq!(normalize_pg_default("42::integer".into()), "42");
        assert_eq!(normalize_pg_default("'2024-01-01'::date".into()), "2024-01-01");
        assert_eq!(
            normalize_pg_default("'2024-01-01 12:00:00'::timestamp without time zone".into()),
            "2024-01-01 12:00:00"
        );
        assert_eq!(normalize_pg_default("'it''s'::text".into()), "it's");
    }

    #[test]
    fn normalize_pg_default_leaves_function_calls_alone() {
        // now() has no cast — return as-is.
        assert_eq!(normalize_pg_default("now()".into()), "now()");
        assert_eq!(normalize_pg_default("CURRENT_TIMESTAMP".into()), "CURRENT_TIMESTAMP");
        // Already-unquoted expression: untouched.
        assert_eq!(normalize_pg_default("gen_random_uuid()".into()), "gen_random_uuid()");
    }

    #[test]
    fn normalize_pg_default_handles_nested_casts() {
        // (a::int + b)::numeric → strip outer ::numeric, leave inner alone.
        assert_eq!(normalize_pg_default("(a::int + b)::numeric".into()), "(a::int + b)");
    }

    #[test]
    fn normalize_pg_default_unquoted_string_passthrough() {
        // Already-unquoted (e.g. legacy MySQL-style) — no double-strip.
        assert_eq!(normalize_pg_default("hello".into()), "hello");
        assert_eq!(normalize_pg_default("'unbalanced".into()), "'unbalanced");
    }
}

/// A column type from the name the catalogue gave, classified by the
/// shared rules. The engine's own spelling is kept for DDL.
fn column_type_of(type_name: &str) -> ColumnType {
    let kind = classify_type_name(type_name);
    ColumnType::new(
        SqlTypeExpr::from_catalog_text(type_name),
        kind,
        CatalogType::Named(SqlTypeExpr::from_catalog_text(type_name)),
        has_dynamic_storage(kind),
        ReadForm::Native,
    )
}

/// A value the driver could not read, so the grid says so rather than
/// showing an empty cell that looks like a NULL.
fn undecodable(type_name: &str) -> Value {
    Value::Undecodable(Box::new(tablepro_core::value::UndecodedValue {
        type_name: type_name.to_owned(),
        reason: tablepro_core::value::UndecodableReason::UnsupportedType,
    }))
}

/// A decimal in the form the PostgreSQL wire protocol takes.
///
/// `None` when the value needs more digits than that type holds, so
/// the caller can refuse rather than round. Reading is not limited
/// this way: `numeric_cell` takes the wire form as it arrives.
fn to_pg_decimal(value: &tablepro_core::value::SqlDecimal) -> Option<rust_decimal::Decimal> {
    let (mantissa, scale) = value.to_scaled_i128()?;
    rust_decimal::Decimal::try_from_i128_with_scale(mantissa, scale).ok()
}

/// A JSON document read back as the server rendered it.
///
/// Decoding through a JSON type and printing it again would reorder
/// the keys and drop the spacing, so the bytes are taken as they
/// arrive. JSONB's binary form puts a version byte first.
fn json_cell(row: &PgRow, idx: usize, type_name: &str) -> Value {
    let Ok(raw) = row.try_get_raw(idx) else {
        return undecodable(type_name);
    };
    if raw.is_null() {
        return Value::Null;
    }
    let Ok(bytes) = raw.as_bytes() else {
        return undecodable(type_name);
    };
    let text = match (raw.format(), type_name) {
        (sqlx::postgres::PgValueFormat::Binary, "JSONB") => match bytes.split_first() {
            Some((&JSONB_VERSION, rest)) => rest,
            _ => return undecodable(type_name),
        },
        _ => bytes,
    };
    std::str::from_utf8(text)
        .ok()
        .and_then(|text| JsonText::parse(text.to_owned()).ok())
        .map(Value::Json)
        .unwrap_or_else(|| undecodable(type_name))
}

const JSONB_VERSION: u8 = 1;

/// A NUMERIC read back at the exact digits the server holds.
///
/// Neither fixed-width nor arbitrary-precision decimal decoding is
/// enough here: the first rounds a number past its own width, and the
/// second drops the declared scale, so `12345.67890` comes back as
/// `12345.6789`. The wire form carries both, so it is read directly.
fn numeric_cell(row: &PgRow, idx: usize, type_name: &str) -> Value {
    let Ok(raw) = row.try_get_raw(idx) else {
        return undecodable(type_name);
    };
    if raw.is_null() {
        return Value::Null;
    }
    let Ok(bytes) = raw.as_bytes() else {
        return undecodable(type_name);
    };
    let text = match raw.format() {
        sqlx::postgres::PgValueFormat::Text => std::str::from_utf8(bytes).map(str::to_owned).ok(),
        sqlx::postgres::PgValueFormat::Binary => numeric_text(bytes),
    };
    text.as_deref()
        .and_then(numeric_value)
        .unwrap_or_else(|| undecodable(type_name))
}

/// A NUMERIC in its binary form: the base-10000 digit count, the
/// position of the first digit, a sign, the declared scale, then the
/// digits themselves. Rendered here the way the server prints it,
/// trailing zeros of the scale included.
fn numeric_text(bytes: &[u8]) -> Option<String> {
    let header: [u8; 8] = bytes.get(..8)?.try_into().ok()?;
    let digit_count = usize::from(u16::from_be_bytes([header[0], header[1]]));
    let weight = i32::from(i16::from_be_bytes([header[2], header[3]]));
    let sign = u16::from_be_bytes([header[4], header[5]]);
    let scale = usize::from(u16::from_be_bytes([header[6], header[7]]));
    match sign {
        SIGN_POSITIVE | SIGN_NEGATIVE => {}
        SIGN_NAN => return Some("NaN".to_owned()),
        SIGN_POSITIVE_INFINITY => return Some("Infinity".to_owned()),
        SIGN_NEGATIVE_INFINITY => return Some("-Infinity".to_owned()),
        _ => return None,
    }
    let digits: Vec<u16> = (0..digit_count)
        .map(|position| {
            let start = 8 + position * 2;
            let pair: [u8; 2] = bytes.get(start..start + 2)?.try_into().ok()?;
            Some(u16::from_be_bytes(pair))
        })
        .collect::<Option<_>>()?;
    let digit_at = |position: i32| -> u16 {
        usize::try_from(position)
            .ok()
            .and_then(|at| digits.get(at).copied())
            .unwrap_or(0)
    };

    let mut text = String::new();
    if sign == SIGN_NEGATIVE {
        text.push('-');
    }
    if weight < 0 {
        text.push('0');
    } else {
        for position in 0..=weight {
            if position == 0 {
                text.push_str(&digit_at(position).to_string());
            } else {
                text.push_str(&format!("{:04}", digit_at(position)));
            }
        }
    }
    if scale > 0 {
        let mut fraction = String::with_capacity(scale + 4);
        let mut position = weight + 1;
        while fraction.len() < scale {
            let digit = if position < 0 { 0 } else { digit_at(position) };
            fraction.push_str(&format!("{digit:04}"));
            position += 1;
        }
        fraction.truncate(scale);
        text.push('.');
        text.push_str(&fraction);
    }
    Some(text)
}

const SIGN_POSITIVE: u16 = 0x0000;
const SIGN_NEGATIVE: u16 = 0x4000;
const SIGN_NAN: u16 = 0xC000;
const SIGN_POSITIVE_INFINITY: u16 = 0xD000;
const SIGN_NEGATIVE_INFINITY: u16 = 0xF000;

/// NUMERIC also carries `NaN` and the infinities, which have no
/// decimal form.
fn numeric_value(text: &str) -> Option<Value> {
    match text.trim().to_ascii_lowercase().as_str() {
        "nan" => Some(Value::Float64(f64::NAN)),
        "infinity" => Some(Value::Float64(f64::INFINITY)),
        "-infinity" => Some(Value::Float64(f64::NEG_INFINITY)),
        _ => text.parse().ok().map(Value::Decimal),
    }
}

/// A bit string in the form the wire carries: the bit count, then the
/// bits packed high end first.
fn bits_value(bits: &sqlx::types::BitVec) -> Option<Value> {
    let bit_len = u32::try_from(bits.len()).ok()?;
    BitString::from_bytes(bit_len, bits.to_bytes()).ok().map(Value::Bits)
}

#[cfg(test)]
mod value_tests {
    use super::*;

    fn numeric_bytes(weight: i16, sign: u16, scale: u16, digits: &[u16]) -> Vec<u8> {
        let mut bytes = Vec::new();
        let count = u16::try_from(digits.len()).unwrap_or(0);
        bytes.extend_from_slice(&count.to_be_bytes());
        bytes.extend_from_slice(&weight.to_be_bytes());
        bytes.extend_from_slice(&sign.to_be_bytes());
        bytes.extend_from_slice(&scale.to_be_bytes());
        for digit in digits {
            bytes.extend_from_slice(&digit.to_be_bytes());
        }
        bytes
    }

    #[test]
    fn numeric_keeps_its_declared_scale() {
        // 12345.67890 as the server sends it: 1 | 2345 | 6789 | 0000,
        // with a declared scale of 5.
        let bytes = numeric_bytes(1, SIGN_POSITIVE, 5, &[1, 2345, 6789, 0]);

        assert_eq!(numeric_text(&bytes).as_deref(), Some("12345.67890"));
    }

    #[test]
    fn a_numeric_wider_than_a_fixed_decimal_survives() {
        // 30 integer digits and 9 fractional ones, past the 28 a
        // fixed-width decimal type holds.
        let bytes = numeric_bytes(
            7,
            SIGN_POSITIVE,
            9,
            &[12, 3456, 7890, 1234, 5678, 9012, 3456, 7890, 1234, 5678, 9000],
        );

        let text = numeric_text(&bytes).expect("the wire form reads");
        assert_eq!(text, "123456789012345678901234567890.123456789");
        let Some(Value::Decimal(decimal)) = numeric_value(&text) else {
            panic!("a wide numeric did not parse");
        };
        assert_eq!(decimal.to_string(), "123456789012345678901234567890.123456789");
    }

    #[test]
    fn a_numeric_below_one_keeps_its_leading_zeros() {
        // 0.00001234, whose first digit group sits two places past the
        // decimal point.
        let bytes = numeric_bytes(-2, SIGN_POSITIVE, 8, &[1234]);

        assert_eq!(numeric_text(&bytes).as_deref(), Some("0.00001234"));
    }

    #[test]
    fn a_negative_numeric_keeps_its_sign() {
        let bytes = numeric_bytes(0, SIGN_NEGATIVE, 2, &[42, 5000]);

        assert_eq!(numeric_text(&bytes).as_deref(), Some("-42.50"));
    }

    #[test]
    fn numeric_carries_the_non_finite_values_postgres_allows() {
        let nan = numeric_text(&numeric_bytes(0, SIGN_NAN, 0, &[]));
        assert_eq!(nan.as_deref(), Some("NaN"));
        assert!(matches!(numeric_value("NaN"), Some(Value::Float64(v)) if v.is_nan()));

        let negative = numeric_text(&numeric_bytes(0, SIGN_NEGATIVE_INFINITY, 0, &[]));
        assert_eq!(negative.as_deref(), Some("-Infinity"));
        assert_eq!(numeric_value("-Infinity"), Some(Value::Float64(f64::NEG_INFINITY)));
    }

    #[test]
    fn a_truncated_numeric_is_refused() {
        assert_eq!(numeric_text(&[0, 1, 0, 0]), None, "a short header was read anyway");
        assert_eq!(
            numeric_text(&numeric_bytes(0, SIGN_POSITIVE, 0, &[1])[..9]),
            None,
            "a missing digit was read anyway"
        );
    }

    #[test]
    fn a_bit_string_keeps_its_length() {
        let mut bits = sqlx::types::BitVec::from_elem(5, false);
        for position in [0, 2, 3] {
            bits.set(position, true);
        }

        let Some(Value::Bits(read)) = bits_value(&bits) else {
            panic!("a bit string did not convert");
        };

        assert_eq!(read.bit_len(), 5);
        assert_eq!(read.to_string(), "10110");
    }
}

#[cfg(test)]
mod decimal_tests {
    use super::*;

    #[test]
    fn a_decimal_the_wire_type_holds_converts_exactly() {
        let value: tablepro_core::value::SqlDecimal = "12345.67890".parse().expect("a decimal");

        let converted = to_pg_decimal(&value).expect("the wire form");

        assert_eq!(converted.to_string(), "12345.67890", "the declared scale was trimmed");
    }

    #[test]
    fn a_decimal_wider_than_the_wire_type_is_refused_rather_than_rounded() {
        // 39 digits, past what the wire type carries.
        let wide: tablepro_core::value::SqlDecimal = "123456789012345678901234567890123456789"
            .parse()
            .expect("a wide decimal");

        assert!(
            to_pg_decimal(&wide).is_none(),
            "a number too wide to send exactly was converted anyway"
        );
    }
}
