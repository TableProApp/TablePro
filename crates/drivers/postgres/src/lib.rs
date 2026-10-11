use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Connection as SqlxConnection, Pool, Postgres, Row};

use tablepro_core::{
    CONTROL_SETUP_TIMEOUT, ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult,
    ForeignKeyInfo, IndexInfo, MAX_QUERY_ROWS, OperationControl, QualifiedTypeName, QueryResult, TableInfo, Transport,
    Value, check_pre_dispatch, run_controlled_setup, run_server_cancellable,
};

mod array;
mod catalog;
mod decode;
mod numeric;
mod params;
mod query;
mod session;
mod temporal;
mod transaction;

use params::{bind_pg_params, describe_query_parameters, needs_text_type_inference};
use query::{
    QueryStop, execute_connection, execute_connection_once, query_connection, query_connection_once, stream_into_result,
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

    fn default_database(&self) -> &'static str {
        "postgres"
    }

    fn default_username(&self) -> &'static str {
        "postgres"
    }

    fn ddl_is_transactional(&self) -> bool {
        true
    }

    fn supports_database_listing(&self) -> bool {
        true
    }

    fn supports_index_metadata(&self) -> bool {
        true
    }

    fn supports_foreign_key_metadata(&self) -> bool {
        true
    }

    fn catalog_object_kinds(&self) -> &'static [tablepro_core::CatalogObjectKind] {
        catalog::SUPPORTED_KINDS
    }

    fn supports_view_metadata(&self) -> bool {
        true
    }

    fn forwarded_socket_name(&self, service_port: u16) -> Option<String> {
        Some(format!(".s.PGSQL.{service_port}"))
    }

    fn supports_local_socket(&self) -> bool {
        true
    }

    fn supports_client_tls_auth(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        use tablepro_core::TlsMode;
        let mut pg_opts = match opts.transport() {
            Transport::Tcp { host, port } => PgConnectOptions::new().host(host).port(port),
            Transport::Socket {
                directory,
                identity_host,
                identity_port,
                ..
            } => PgConnectOptions::new()
                .host(identity_host)
                .port(identity_port)
                .socket(directory),
        };
        pg_opts = pg_opts
            .database(&opts.database)
            .username(&opts.username)
            .password(opts.password.expose_secret())
            .ssl_mode(match opts.tls.mode {
                TlsMode::Disabled => sqlx::postgres::PgSslMode::Disable,
                TlsMode::Prefer => sqlx::postgres::PgSslMode::Prefer,
                TlsMode::Require => sqlx::postgres::PgSslMode::Require,
                TlsMode::VerifyCa => sqlx::postgres::PgSslMode::VerifyCa,
                TlsMode::VerifyFull => sqlx::postgres::PgSslMode::VerifyFull,
            });
        if let Some(path) = &opts.tls.root_cert {
            pg_opts = pg_opts.ssl_root_cert(path);
        }
        if let Some(path) = &opts.tls.client_cert {
            pg_opts = pg_opts.ssl_client_cert(path);
        }
        if let Some(path) = &opts.tls.client_key {
            pg_opts = pg_opts.ssl_client_key(path);
        }
        if let Some(name) = &opts.application_name {
            pg_opts = pg_opts.application_name(name);
        }
        if opts.read_only {
            pg_opts = pg_opts.options([("default_transaction_read_only", "on")]);
        }
        let cancellation_options = pg_opts.clone();
        let session_options = pg_opts.clone();
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(pg_opts)
            .await
            .map_err(map_sqlx_connect_error)?;
        // Lazy: a saved connection with a failed-login lockout policy
        // must not see two authentication attempts for one Connect
        // click. The real dial happens only when a cancel is actually
        // requested.
        let cancellation_pool = PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(5))
            .connect_lazy_with(cancellation_options);
        Ok(Box::new(PgConnection {
            pool,
            cancellation_pool,
            session_options,
        }))
    }
}

struct PgConnection {
    pool: Pool<Postgres>,
    cancellation_pool: Pool<Postgres>,
    session_options: PgConnectOptions,
}

#[async_trait]
impl Connection for PgConnection {
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        let rows = sqlx::query(
            "SELECT datname FROM pg_database
             WHERE datallowconn AND NOT datistemplate AND has_database_privilege(datname, 'CONNECT')
             ORDER BY datname",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows.into_iter().map(|row| row.get::<String, _>(0)).collect())
    }

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

    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT schemaname, viewname FROM (
                 SELECT schemaname, viewname FROM pg_views
                 UNION ALL
                 SELECT schemaname, matviewname FROM pg_matviews
             ) AS relations
             WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
             ORDER BY schemaname, viewname",
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

    async fn list_objects(
        &self,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<&str>,
    ) -> Result<Vec<tablepro_core::CatalogObject>, DriverError> {
        catalog::list_objects(&self.pool, kind, schema).await
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
        //   - col_description() is the column-level comment accessor;
        //     obj_description() answers for the relation, so using it
        //     here would give every column the table's comment.
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
                pg_catalog.col_description(a.attrelid, a.attnum) AS column_comment,
                CASE WHEN a.attcollation <> 0 AND a.attcollation <> ty.typcollation
                    THEN co.collname::text END AS collation,
                type_ns.nspname AS enum_schema,
                enum_ty.typname AS enum_name,
                CASE WHEN ty.typtype = 'd' THEN domain_ns.nspname END AS domain_schema,
                CASE WHEN ty.typtype = 'd' THEN ty.typname END AS domain_name
             FROM pg_catalog.pg_attribute a
             JOIN pg_catalog.pg_class t ON a.attrelid = t.oid
             JOIN pg_catalog.pg_namespace n ON t.relnamespace = n.oid
             JOIN pg_catalog.pg_type ty ON ty.oid = a.atttypid
             LEFT JOIN LATERAL (
                 WITH RECURSIVE type_chain(oid, typtype, typbasetype, typnamespace, typname) AS (
                     SELECT candidate.oid, candidate.typtype, candidate.typbasetype,
                            candidate.typnamespace, candidate.typname
                     FROM pg_catalog.pg_type candidate
                     WHERE candidate.oid = CASE
                         WHEN ty.typcategory = 'A' AND EXISTS (
                             SELECT 1 FROM pg_catalog.pg_type element
                             WHERE element.oid = ty.typelem AND element.typtype IN ('e', 'd')
                         ) THEN ty.typelem
                         ELSE ty.oid
                     END
                     UNION ALL
                     SELECT base.oid, base.typtype, base.typbasetype,
                            base.typnamespace, base.typname
                     FROM pg_catalog.pg_type base
                     JOIN type_chain ON base.oid = type_chain.typbasetype
                     WHERE type_chain.typtype = 'd'
                 )
                 SELECT typnamespace, typname
                 FROM type_chain
                 WHERE typtype = 'e'
                    OR (ty.typcategory = 'A' AND oid = ty.typelem AND typtype = 'd')
                 ORDER BY CASE
                     WHEN ty.typcategory = 'A' AND oid = ty.typelem AND typtype = 'd' THEN 0
                     ELSE 1
                 END
                 LIMIT 1
             ) enum_ty ON TRUE
             LEFT JOIN pg_catalog.pg_namespace type_ns ON type_ns.oid = enum_ty.typnamespace
             LEFT JOIN pg_catalog.pg_namespace domain_ns ON domain_ns.oid = ty.typnamespace
             LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
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
                let enum_schema = r.try_get::<Option<String>, _>(9).map_err(map_sqlx_error)?;
                let enum_name = r.try_get::<Option<String>, _>(10).map_err(map_sqlx_error)?;
                let domain_schema = r.try_get::<Option<String>, _>(11).map_err(map_sqlx_error)?;
                let domain_name = r.try_get::<Option<String>, _>(12).map_err(map_sqlx_error)?;
                Ok(ColumnInfo {
                    name: r.get::<String, _>(0),
                    data_type: r.get::<String, _>(1),
                    nullable: r.get::<bool, _>(2),
                    primary_key: r.get::<bool, _>(3),
                    is_auto_increment: is_identity || is_serial,
                    default_value,
                    is_generated,
                    comment: r
                        .try_get::<Option<String>, _>(7)
                        .unwrap_or(None)
                        .filter(|c| !c.is_empty()),
                    collation: r.try_get::<Option<String>, _>(8).unwrap_or(None),
                    enum_type: enum_schema
                        .zip(enum_name)
                        .map(|(schema, name)| QualifiedTypeName { schema, name }),
                    domain_type: domain_schema
                        .zip(domain_name)
                        .map(|(schema, name)| QualifiedTypeName { schema, name }),
                })
            })
            .collect::<Result<Vec<_>, DriverError>>()?)
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

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let backend_pid = backend_pid_controlled(&mut connection, control).await?;
        let (connection, result) = controlled_query(
            connection,
            &self.cancellation_pool,
            backend_pid,
            sql,
            &[],
            true,
            control,
        )
        .await;
        drop(connection);
        result
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        let backend_pid = backend_pid(&mut connection).await?;
        let stop = Some(QueryStop {
            pool: &self.cancellation_pool,
            backend_pid,
        });
        query_connection(&mut connection, sql, params, stop).await
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let backend_pid = backend_pid_controlled(&mut connection, control).await?;
        let (connection, result) = controlled_query(
            connection,
            &self.cancellation_pool,
            backend_pid,
            sql,
            params,
            true,
            control,
        )
        .await;
        drop(connection);
        result
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        execute_connection(&mut connection, sql, &[]).await
    }

    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let backend_pid = backend_pid_controlled(&mut connection, control).await?;
        let (connection, result) = controlled_execute(
            connection,
            &self.cancellation_pool,
            backend_pid,
            sql,
            &[],
            true,
            control,
        )
        .await;
        drop(connection);
        result
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        execute_connection(&mut connection, sql, params).await
    }

    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let backend_pid = backend_pid_controlled(&mut connection, control).await?;
        let (connection, result) = controlled_execute(
            connection,
            &self.cancellation_pool,
            backend_pid,
            sql,
            params,
            true,
            control,
        )
        .await;
        drop(connection);
        result
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.execute_in_transaction_checked(statements, &[]).await
    }

    async fn execute_in_transaction_checked(
        &self,
        statements: &[(String, Vec<Value>)],
        expect_one: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        transaction::execute_in_transaction_checked(&self.pool, statements, expect_one).await
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // `indkey` holds 0 for an expression key and lists INCLUDE columns
        // after the first `indnkeyatts` key columns; the expression text
        // comes from `pg_get_indexdef` at that key position.
        let rows = sqlx::query(
            "SELECT
                i.relname AS index_name,
                ix.indisunique,
                ix.indisprimary,
                ARRAY(
                    SELECT CASE WHEN k.attnum = 0
                        THEN pg_catalog.pg_get_indexdef(ix.indexrelid, k.ordinality::int, true)
                        ELSE a.attname::text END
                    FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ordinality)
                    LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum
                    WHERE k.ordinality <= ix.indnkeyatts
                    ORDER BY k.ordinality
                ) AS columns,
                pg_catalog.pg_get_expr(ix.indpred, ix.indrelid, true) AS predicate
            FROM pg_catalog.pg_class t
            JOIN pg_catalog.pg_namespace n ON t.relnamespace = n.oid
            JOIN pg_catalog.pg_index ix ON ix.indrelid = t.oid
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            WHERE n.nspname = COALESCE($2, current_schema())
              AND t.relname = $1
            ORDER BY i.relname",
        )
        .bind(table)
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        rows.into_iter()
            .map(|r| {
                Ok(IndexInfo {
                    name: r.try_get(0).map_err(map_sqlx_error)?,
                    unique: r.try_get(1).map_err(map_sqlx_error)?,
                    primary: r.try_get(2).map_err(map_sqlx_error)?,
                    columns: r.try_get(3).map_err(map_sqlx_error)?,
                    predicate: r.try_get(4).map_err(map_sqlx_error)?,
                })
            })
            .collect()
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
                c.confdeltype::text AS on_delete_code,
                c.confupdtype::text AS on_update_code
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

    fn supports_server_cancellation(&self) -> bool {
        true
    }

    async fn ping(&self) -> Result<(), DriverError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(())
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        session::open(&self.session_options, self.cancellation_pool.clone()).await
    }

    async fn begin(&self) -> Result<Box<dyn tablepro_core::Transaction>, DriverError> {
        let mut connection = tokio::time::timeout(CONTROL_SETUP_TIMEOUT, self.pool.acquire())
            .await
            .map_err(|_| DriverError::TimedOut)?
            .map_err(map_sqlx_error)?;
        let backend_pid = tokio::time::timeout(CONTROL_SETUP_TIMEOUT, backend_pid(&mut connection))
            .await
            .map_err(|_| DriverError::TimedOut)??;
        sqlx::query("BEGIN")
            .execute(&mut *connection)
            .await
            .map_err(map_sqlx_error)?;
        Ok(Box::new(PgTransaction {
            connection: Some(connection),
            cancellation_pool: self.cancellation_pool.clone(),
            backend_pid,
        }))
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let row = sqlx::query("SHOW server_version")
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let v: String = row.try_get(0).unwrap_or_default();
        Ok(Some(format!("PostgreSQL {v}")))
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        self.cancellation_pool.close().await;
        Ok(())
    }
}

async fn transaction_failure(
    tx: sqlx::Transaction<'static, Postgres>,
    statement_index: usize,
    source: DriverError,
) -> DriverError {
    match tx.rollback().await {
        Ok(()) => DriverError::Transaction {
            statement_index,
            source: Box::new(source),
        },
        Err(error) => DriverError::TransactionRollbackFailed {
            statement_index,
            source: Box::new(source),
            rollback_error: Box::new(map_sqlx_error(error)),
        },
    }
}

struct PgTransaction {
    connection: Option<PoolConnection<Postgres>>,
    cancellation_pool: Pool<Postgres>,
    backend_pid: i32,
}

impl Drop for PgTransaction {
    fn drop(&mut self) {
        if let Some(connection) = self.connection.as_mut() {
            connection.close_on_drop();
        }
    }
}

#[async_trait]
impl tablepro_core::Transaction for PgTransaction {
    async fn query(&mut self, sql: &str) -> Result<QueryResult, DriverError> {
        let (pool, backend_pid) = (self.cancellation_pool.clone(), self.backend_pid);
        let stop = Some(QueryStop {
            pool: &pool,
            backend_pid,
        });
        let connection = self.connection_mut()?;
        query_connection_once(connection, sql, &[], stop).await
    }

    async fn query_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        self.query_params_controlled(sql, &[], control).await
    }

    async fn query_params(&mut self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let (pool, backend_pid) = (self.cancellation_pool.clone(), self.backend_pid);
        let stop = Some(QueryStop {
            pool: &pool,
            backend_pid,
        });
        let connection = self.connection_mut()?;
        query_connection_once(connection, sql, params, stop).await
    }

    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let connection = self.take_connection()?;
        let (connection, result) = controlled_query(
            connection,
            &self.cancellation_pool,
            self.backend_pid,
            sql,
            params,
            // An error aborts an explicit transaction; the caller must roll it back.
            false,
            control,
        )
        .await;
        self.connection = connection;
        result
    }

    async fn execute(&mut self, sql: &str) -> Result<ExecResult, DriverError> {
        let connection = self.connection_mut()?;
        execute_connection_once(connection, sql, &[]).await
    }

    async fn execute_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        self.execute_params_controlled(sql, &[], control).await
    }

    async fn execute_params(&mut self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let connection = self.connection_mut()?;
        execute_connection_once(connection, sql, params).await
    }

    async fn execute_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        check_pre_dispatch(control)?;
        let connection = self.take_connection()?;
        let (connection, result) = controlled_execute(
            connection,
            &self.cancellation_pool,
            self.backend_pid,
            sql,
            params,
            // An error aborts an explicit transaction; the caller must roll it back.
            false,
            control,
        )
        .await;
        self.connection = connection;
        result
    }

    async fn commit(mut self: Box<Self>) -> Result<(), DriverError> {
        let connection = self.connection_mut()?;
        sqlx::query("COMMIT")
            .execute(&mut **connection)
            .await
            .map_err(map_sqlx_error)?;
        let _ = self.take_connection()?;
        Ok(())
    }

    async fn rollback(mut self: Box<Self>) -> Result<(), DriverError> {
        let connection = self.connection_mut()?;
        sqlx::query("ROLLBACK")
            .execute(&mut **connection)
            .await
            .map_err(map_sqlx_error)?;
        let _ = self.take_connection()?;
        Ok(())
    }
}

impl PgTransaction {
    fn connection_mut(&mut self) -> Result<&mut PoolConnection<Postgres>, DriverError> {
        self.connection
            .as_mut()
            .ok_or_else(|| DriverError::Internal("transaction is unusable".into()))
    }

    fn take_connection(&mut self) -> Result<PoolConnection<Postgres>, DriverError> {
        self.connection
            .take()
            .ok_or_else(|| DriverError::Internal("transaction is unusable".into()))
    }
}

async fn acquire_controlled(
    pool: &Pool<Postgres>,
    control: &OperationControl,
) -> Result<PoolConnection<Postgres>, DriverError> {
    run_controlled_setup(pool.acquire(), control)
        .await?
        .map_err(map_sqlx_error)
}

async fn backend_pid_controlled(
    connection: &mut PoolConnection<Postgres>,
    control: &OperationControl,
) -> Result<i32, DriverError> {
    run_controlled_setup(backend_pid(connection), control).await?
}

pub(crate) async fn backend_pid(connection: &mut PoolConnection<Postgres>) -> Result<i32, DriverError> {
    sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut **connection)
        .await
        .map_err(map_sqlx_error)
}

async fn controlled_query(
    mut connection: PoolConnection<Postgres>,
    cancellation_pool: &Pool<Postgres>,
    backend_pid: i32,
    sql: &str,
    params: &[Value],
    retry_stale_type_cache: bool,
    control: &OperationControl,
) -> (Option<PoolConnection<Postgres>>, Result<QueryResult, DriverError>) {
    let stop = Some(QueryStop {
        pool: cancellation_pool,
        backend_pid,
    });
    let result = run_server_cancellable(
        async {
            if retry_stale_type_cache {
                query_connection(&mut connection, sql, params, stop).await
            } else {
                query_connection_once(&mut connection, sql, params, stop).await
            }
        },
        request_cancellation(cancellation_pool, backend_pid),
        confirms_cancellation,
        control,
    )
    .await;
    finish_connection(connection, result).await
}

async fn controlled_execute(
    mut connection: PoolConnection<Postgres>,
    cancellation_pool: &Pool<Postgres>,
    backend_pid: i32,
    sql: &str,
    params: &[Value],
    retry_stale_type_cache: bool,
    control: &OperationControl,
) -> (Option<PoolConnection<Postgres>>, Result<ExecResult, DriverError>) {
    let result = run_server_cancellable(
        async {
            if retry_stale_type_cache {
                execute_connection(&mut connection, sql, params).await
            } else {
                execute_connection_once(&mut connection, sql, params).await
            }
        },
        request_cancellation(cancellation_pool, backend_pid),
        confirms_cancellation,
        control,
    )
    .await;
    finish_connection(connection, result).await
}

fn confirms_cancellation(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Query {
            sqlstate: Some(sqlstate),
            ..
        } if sqlstate == "57014"
    )
}

async fn finish_connection<T>(
    connection: PoolConnection<Postgres>,
    result: Result<T, DriverError>,
) -> (Option<PoolConnection<Postgres>>, Result<T, DriverError>) {
    if matches!(result, Err(DriverError::OperationOutcomeUnknown { .. })) {
        let raw_connection = connection.detach();
        let _ = raw_connection.close_hard().await;
        return (None, result);
    }
    (Some(connection), result)
}

/// `run_server_cancellable` wraps this future in its own dispatch
/// timeout and moves on without it if that elapses. Run the actual
/// round trip in a spawned task instead of inline, so giving up on it
/// here can never drop it mid-response and return a protocol-desynced
/// connection to the single-slot cancellation pool -- the task always
/// finishes and explicitly closes the connection on failure rather than
/// trusting an implicit pool return.
pub(crate) async fn request_cancellation(pool: &Pool<Postgres>, backend_pid: i32) -> Result<(), DriverError> {
    let pool = pool.clone();
    let task = tokio::spawn(async move {
        let mut conn = pool.acquire().await.map_err(map_sqlx_error)?;
        let outcome: Result<bool, DriverError> = sqlx::query_scalar("SELECT pg_cancel_backend($1)")
            .bind(backend_pid)
            .fetch_one(&mut *conn)
            .await
            .map_err(map_sqlx_error);
        if outcome.is_err() {
            let _ = conn.detach().close_hard().await;
        }
        outcome
    });
    let cancelled = match task.await {
        Ok(result) => result?,
        Err(_) => return Err(DriverError::Cancelled),
    };
    if cancelled {
        Ok(())
    } else {
        Err(DriverError::Internal(
            "PostgreSQL rejected the cancellation request".into(),
        ))
    }
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn normalize_pg_default(raw: String) -> String {
    match raw.rsplit_once("::") {
        Some((operand, _)) if is_plain_literal(operand) => operand.to_string(),
        _ => raw,
    }
}

fn is_plain_literal(operand: &str) -> bool {
    is_quoted_literal(operand) || operand.eq_ignore_ascii_case("null") || operand.parse::<f64>().is_ok()
}

fn is_quoted_literal(operand: &str) -> bool {
    let Some(inner) = operand.strip_prefix('\'').and_then(|rest| rest.strip_suffix('\'')) else {
        return false;
    };
    !inner.replace("''", "").contains('\'')
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

fn is_certificate_failure(err: &std::io::Error) -> bool {
    let mut source: Option<&(dyn std::error::Error + 'static)> = Some(err);
    while let Some(current) = source {
        let text = current.to_string().to_ascii_lowercase();
        if text.contains("certificate") || text.contains("tls handshake") {
            return true;
        }
        source = current.source();
    }
    false
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    if is_enum_label_metadata_null(&err) {
        return DriverError::Unsupported(
            "PostgreSQL enum result metadata could not be resolved; the result was not read".into(),
        );
    }
    if matches!(&err, sqlx::Error::Protocol(message) if message.starts_with("unable to resolve type OIDs:")) {
        return DriverError::Unsupported("PostgreSQL type hierarchy exceeds the driver's resolvable depth".into());
    }
    use sqlx::Error::*;
    match err {
        Database(e) => {
            let sqlstate = e.code().map(|c| c.to_string());
            if is_server_disconnect_sqlstate(sqlstate.as_deref()) {
                DriverError::Disconnected
            } else {
                DriverError::Query {
                    message: e.message().to_string(),
                    sqlstate,
                    position: statement_position(e.as_ref()),
                }
            }
        }
        Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => DriverError::ConnectionRefused,
        Io(e) if is_certificate_failure(&e) => DriverError::Tls(e.to_string()),
        Io(_) => DriverError::Disconnected,
        Tls(e) => DriverError::Tls(e.to_string()),
        PoolClosed | PoolTimedOut => DriverError::Disconnected,
        other => DriverError::Internal(format!("{other}")),
    }
}

fn is_enum_label_metadata_null(err: &sqlx::Error) -> bool {
    let sqlx::Error::ColumnDecode { index, source } = err else {
        return false;
    };
    index == "\"enum_labels\"" && source.downcast_ref::<sqlx::error::UnexpectedNullError>().is_some()
}

fn map_sqlx_connect_error(err: sqlx::Error) -> DriverError {
    if is_pool_startup_timeout(&err) {
        // SQLx retries refused pool connections until the acquire deadline,
        // then erases the underlying I/O error into PoolTimedOut. During
        // initial setup there is no established connection to disconnect.
        DriverError::ConnectionRefused
    } else {
        map_sqlx_error(err)
    }
}

fn is_pool_startup_timeout(err: &sqlx::Error) -> bool {
    matches!(err, sqlx::Error::PoolTimedOut)
}

fn statement_position(error: &dyn sqlx::error::DatabaseError) -> Option<usize> {
    match error
        .try_downcast_ref::<sqlx::postgres::PgDatabaseError>()?
        .position()?
    {
        sqlx::postgres::PgErrorPosition::Original(position) => Some(position),
        sqlx::postgres::PgErrorPosition::Internal { .. } => None,
    }
}

fn is_server_disconnect_sqlstate(sqlstate: Option<&str>) -> bool {
    matches!(sqlstate, Some("57P01" | "57P02" | "57P03" | "57P04"))
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
