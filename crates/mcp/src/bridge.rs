use std::{future::Future, sync::Arc, time::Duration};

use async_trait::async_trait;
use tablepro_core::sql_dialect::{explain_statement, quote_ident};
use tablepro_core::{
    ColumnInfo, Connection, DriverError, ForeignKeyInfo, IndexInfo, OperationControl, QueryResult, QueryResultBatch,
    TableInfo, Value, check_pre_dispatch,
};
use tablepro_policy::Principal;
use tablepro_storage::SavedConnection;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::auth::{McpScope, authorize_scopes};
use crate::rate_limit::RateLimiter;
use crate::tokens::{McpToken, TokenStore};

/// Supplies policy-gated connections. Implementations must never return a
/// raw driver connection that bypasses [`tablepro_policy::PolicyGuard`].
#[async_trait]
pub trait ConnectionProvider: Send + Sync {
    async fn list_saved_connections(&self) -> Result<Vec<SavedConnection>, String>;
    async fn connection(&self, connection_id: Uuid, principal: Principal) -> Result<Arc<dyn Connection>, String>;
}

const MAX_IDENTIFIER_BYTES: usize = 256;
const PREVIEW_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);

tokio::task_local! {
    static REQUEST_CANCELLATION: CancellationToken;
}

pub(crate) async fn scope_request_cancellation<F: Future>(cancellation: CancellationToken, future: F) -> F::Output {
    REQUEST_CANCELLATION.scope(cancellation, future).await
}

pub struct McpBridge {
    provider: Arc<dyn ConnectionProvider>,
    tokens: Arc<TokenStore>,
    rate_limiter: RateLimiter,
    /// Bounds every call to `authenticate`, not just successful ones. It is
    /// keyed on a single fixed key rather than the bearer string tried --
    /// a brute-force caller sends a different string on every attempt, so
    /// keying on the string would never throttle it -- so this bounds the
    /// aggregate rate of authentication attempts against the whole server.
    /// Without it, a failed authenticate never resolves to a token id to
    /// key `rate_limiter` on, so it was unbounded: unlimited guesses, each
    /// one taking the same cross-process token-store file lock issue and
    /// revoke need.
    auth_rate_limiter: RateLimiter,
    shutdown: CancellationToken,
    pub max_rows: u64,
    pub query_timeout_secs: u64,
}

const AUTH_ATTEMPT_KEY: &str = "authenticate";

#[derive(Debug, Clone, Copy)]
pub struct McpLimits {
    pub requests_per_minute: u32,
    pub max_rows: u64,
    pub query_timeout_secs: u64,
}

impl Default for McpLimits {
    fn default() -> Self {
        Self {
            requests_per_minute: 120,
            max_rows: 500,
            query_timeout_secs: 30,
        }
    }
}

impl McpBridge {
    pub fn new(provider: Arc<dyn ConnectionProvider>, tokens: Arc<TokenStore>) -> Self {
        Self::with_limits(provider, tokens, McpLimits::default())
    }

    pub fn with_limits(provider: Arc<dyn ConnectionProvider>, tokens: Arc<TokenStore>, limits: McpLimits) -> Self {
        Self::with_limits_and_shutdown(provider, tokens, limits, CancellationToken::new())
    }

    pub fn with_shutdown_token(
        provider: Arc<dyn ConnectionProvider>,
        tokens: Arc<TokenStore>,
        shutdown: CancellationToken,
    ) -> Self {
        Self::with_limits_and_shutdown(provider, tokens, McpLimits::default(), shutdown)
    }

    fn with_limits_and_shutdown(
        provider: Arc<dyn ConnectionProvider>,
        tokens: Arc<TokenStore>,
        limits: McpLimits,
        shutdown: CancellationToken,
    ) -> Self {
        Self {
            provider,
            tokens,
            rate_limiter: RateLimiter::new(limits.requests_per_minute),
            auth_rate_limiter: RateLimiter::new(limits.requests_per_minute),
            shutdown,
            max_rows: limits.max_rows,
            query_timeout_secs: limits.query_timeout_secs,
        }
    }

    pub fn shutdown(&self) {
        self.shutdown.cancel();
    }

    pub(crate) fn request_cancellation(&self) -> CancellationToken {
        self.shutdown.child_token()
    }

    fn operation_control(&self) -> OperationControl {
        let cancellation = REQUEST_CANCELLATION
            .try_with(Clone::clone)
            .unwrap_or_else(|_| self.shutdown.clone());
        operation_control(cancellation.child_token(), self.query_timeout_secs)
    }

    pub fn tokens(&self) -> &TokenStore {
        &self.tokens
    }

    pub fn authenticate(&self, bearer: &str) -> Result<McpToken, String> {
        self.auth_rate_limiter.check(AUTH_ATTEMPT_KEY)?;
        let token = bearer.strip_prefix("Bearer ").unwrap_or(bearer).trim();
        self.tokens.authenticate(token)
    }

    pub fn check_rate(&self, token: &McpToken) -> Result<(), String> {
        self.rate_limiter.check(&token.id.to_string())
    }

    pub fn ensure_connection_allowed(&self, token: &McpToken, connection_id: Uuid) -> Result<(), String> {
        if token.connection_allowlist.is_empty() {
            return Err("token has an empty connection allowlist".into());
        }
        if token.connection_allowlist.contains(&connection_id) {
            Ok(())
        } else {
            Err("token is not allowed to access this connection".into())
        }
    }

    pub async fn list_connections(&self, token: &McpToken) -> Result<Vec<SavedConnection>, String> {
        let control = self.operation_control();
        authorize_scopes(token.permissions, McpScope::ToolsRead)?;
        self.check_rate(token)?;
        if token.connection_allowlist.is_empty() {
            return Ok(Vec::new());
        }
        let mut list = run_bounded(self.provider.list_saved_connections(), &control)
            .await
            .map_err(|error| error.to_string())??;
        list.retain(|connection| token.connection_allowlist.contains(&connection.id));
        self.ensure_operation_active(&control)?;
        Ok(list)
    }

    pub async fn with_connection<F, T>(&self, token: &McpToken, connection_id: Uuid, f: F) -> Result<T, String>
    where
        F: FnOnce(
                Arc<dyn Connection>,
                OperationControl,
            ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, String>> + Send>>
            + Send,
        T: Send,
    {
        let control = self.start_connection_operation(token, connection_id)?;
        self.with_connection_controlled(token, connection_id, control, f).await
    }

    pub(crate) fn ensure_operation_active(&self, control: &OperationControl) -> Result<(), String> {
        check_pre_dispatch(control).map_err(|error| error.to_string())
    }

    pub(crate) fn start_connection_operation(
        &self,
        token: &McpToken,
        connection_id: Uuid,
    ) -> Result<OperationControl, String> {
        let control = self.operation_control();
        authorize_scopes(token.permissions, McpScope::ToolsRead)?;
        self.check_rate(token)?;
        self.ensure_connection_allowed(token, connection_id)?;
        Ok(control)
    }

    async fn with_connection_controlled<F, T>(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        control: OperationControl,
        f: F,
    ) -> Result<T, String>
    where
        F: FnOnce(
                Arc<dyn Connection>,
                OperationControl,
            ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, String>> + Send>>
            + Send,
        T: Send,
    {
        let principal = Principal::Agent {
            token: token.id.to_string(),
            client: Some(token.name.clone()),
            model: None,
        };
        let conn = run_bounded(self.provider.connection(connection_id, principal), &control)
            .await
            .map_err(|error| error.to_string())??;
        f(conn, control).await
    }

    async fn driver_id_for_controlled(
        &self,
        connection_id: Uuid,
        control: &OperationControl,
    ) -> Result<String, String> {
        run_bounded(self.provider.list_saved_connections(), control)
            .await
            .map_err(|error| error.to_string())??
            .into_iter()
            .find(|connection| connection.id == connection_id)
            .map(|connection| connection.driver_id)
            .ok_or_else(|| format!("connection {connection_id} not found"))
    }

    pub async fn list_tables(&self, token: &McpToken, connection_id: Uuid) -> Result<Vec<TableInfo>, String> {
        self.with_connection(token, connection_id, |conn, control| {
            Box::pin(async move {
                conn.list_tables_controlled(&control)
                    .await
                    .map_err(|error| error.to_string())
            })
        })
        .await
    }

    pub async fn list_objects(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        kind: tablepro_core::CatalogObjectKind,
        schema: Option<String>,
    ) -> Result<Vec<tablepro_core::CatalogObject>, String> {
        let schema = match schema {
            Some(schema) => Some(validated_identifier(&schema)?),
            None => None,
        };
        self.with_connection(token, connection_id, move |conn, control| {
            Box::pin(async move {
                conn.list_objects_controlled(kind, schema.as_deref(), &control)
                    .await
                    .map_err(|error| error.to_string())
            })
        })
        .await
    }

    pub async fn describe_table(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        schema: Option<String>,
        table: String,
    ) -> Result<Vec<ColumnInfo>, String> {
        let table = validated_identifier(&table)?;
        let schema = match schema {
            Some(schema) => Some(validated_identifier(&schema)?),
            None => None,
        };
        self.with_connection(token, connection_id, move |conn, control| {
            Box::pin(async move {
                conn.fetch_columns_controlled(schema.as_deref(), &table, &control)
                    .await
                    .map_err(|error| error.to_string())
            })
        })
        .await
    }

    pub async fn execute_query(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        sql: &str,
    ) -> Result<QueryResultBatch, String> {
        let control = self.start_connection_operation(token, connection_id)?;
        self.execute_query_controlled(token, connection_id, sql, None, control)
            .await
    }

    pub(crate) async fn execute_query_controlled(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        sql: &str,
        driver_id: Option<String>,
        control: OperationControl,
    ) -> Result<QueryResultBatch, String> {
        let driver_id = match driver_id {
            Some(driver_id) => driver_id,
            None => self.driver_id_for_controlled(connection_id, &control).await?,
        };
        if sql_looks_like_write(sql, &driver_id) {
            authorize_scopes(token.permissions, McpScope::ToolsWrite)?;
            return Err(
                "execute_query only runs reads; call execute_write for a statement that writes, so the \
                 preview-by-default workflow applies"
                    .into(),
            );
        }
        let max_rows = self.max_rows;
        let sql = sql.to_string();
        self.with_connection_controlled(token, connection_id, control, move |conn, control| {
            Box::pin(async move {
                let mut result = conn
                    .query_result_sets_controlled(&sql, &[], &control)
                    .await
                    .map_err(|error| error.to_string())?;
                check_pre_dispatch(&control).map_err(|error| error.to_string())?;
                let mut remaining = max_rows;
                for result_set in &mut result.result_sets {
                    let rows = u64::try_from(result_set.rows.len()).unwrap_or(u64::MAX);
                    if rows > remaining {
                        result_set
                            .rows
                            .truncate(usize::try_from(remaining).unwrap_or(usize::MAX));
                        result_set.truncated = true;
                        result.truncated = true;
                    }
                    remaining = remaining.saturating_sub(u64::try_from(result_set.rows.len()).unwrap_or(u64::MAX));
                }
                check_pre_dispatch(&control).map_err(|error| error.to_string())?;
                Ok(result)
            })
        })
        .await
    }

    pub async fn explain_query(&self, token: &McpToken, connection_id: Uuid, sql: &str) -> Result<QueryResult, String> {
        let control = self.start_connection_operation(token, connection_id)?;
        let driver_id = self.driver_id_for_controlled(connection_id, &control).await?;
        let explain = explain_statement(&driver_id, sql)
            .ok_or_else(|| format!("explain is not supported for the {driver_id} driver"))?;
        self.execute_query_controlled(token, connection_id, &explain, Some(driver_id), control)
            .await
            .map(QueryResultBatch::into_first)
    }

    pub async fn table_schema(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        schema: Option<String>,
        table: String,
    ) -> Result<TableSchema, String> {
        let table = validated_identifier(&table)?;
        let schema = match schema {
            Some(schema) => Some(validated_identifier(&schema)?),
            None => None,
        };
        self.with_connection(token, connection_id, move |conn, control| {
            Box::pin(async move {
                let columns = conn
                    .fetch_columns_controlled(schema.as_deref(), &table, &control)
                    .await
                    .map_err(|e| e.to_string())?;
                let indexes = conn
                    .fetch_indexes_controlled(schema.as_deref(), &table, &control)
                    .await
                    .map_err(|error| error.to_string())?;
                let foreign_keys = conn
                    .fetch_foreign_keys_controlled(schema.as_deref(), &table, &control)
                    .await
                    .map_err(|error| error.to_string())?;
                Ok(TableSchema {
                    columns,
                    indexes,
                    foreign_keys,
                })
            })
        })
        .await
    }

    pub async fn count_rows(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        schema: Option<String>,
        table: String,
    ) -> Result<u64, String> {
        let control = self.start_connection_operation(token, connection_id)?;
        let driver_id = self.driver_id_for_controlled(connection_id, &control).await?;
        let sql = count_statement(&driver_id, schema.as_deref(), &table)?;
        let result = self
            .execute_query_controlled(token, connection_id, &sql, Some(driver_id), control.clone())
            .await?;
        self.ensure_operation_active(&control)?;
        let value = result
            .result_sets
            .first()
            .and_then(|set| set.rows.first())
            .and_then(|row| row.first())
            .ok_or("the engine returned no count row")?;
        let count = count_from_value(value)?;
        self.ensure_operation_active(&control)?;
        Ok(count)
    }

    pub async fn browse_table(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        schema: Option<String>,
        table: String,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, String> {
        let table = validated_identifier(&table)?;
        let schema = match schema {
            Some(schema) => Some(validated_identifier(&schema)?),
            None => None,
        };
        let capped = limit.clamp(1, self.max_rows);
        self.with_connection(token, connection_id, move |conn, control| {
            Box::pin(async move {
                let mut result = conn
                    .fetch_rows_controlled(schema.as_deref(), &table, offset, capped, &control)
                    .await
                    .map_err(|e| e.to_string())?;
                if result.rows.len() as u64 > capped {
                    result.rows.truncate(capped as usize);
                    result.truncated = true;
                }
                if limit > capped {
                    result.truncated = true;
                }
                Ok(result)
            })
        })
        .await
    }

    pub async fn execute_write(
        &self,
        token: &McpToken,
        connection_id: Uuid,
        sql: &str,
        preview: bool,
    ) -> Result<WriteOutcome, String> {
        authorize_scopes(token.permissions, McpScope::ToolsWrite)?;
        let sql = sql.to_string();
        self.with_connection(token, connection_id, move |conn, control| {
            Box::pin(async move {
                if preview {
                    let mut tx = run_bounded(conn.begin(), &control)
                        .await
                        .map_err(|error| error.to_string())?
                        .map_err(|error| error.to_string())?;
                    let result = tx.execute_controlled(&sql, &control).await;
                    let cleanup_control = operation_control_for(CancellationToken::new(), PREVIEW_CLEANUP_TIMEOUT);
                    tx.rollback_controlled(&cleanup_control)
                        .await
                        .map_err(|error| format!("preview rollback could not be confirmed: {error}"))?;
                    let result = result.map_err(|error| error.to_string())?;
                    Ok(WriteOutcome::Preview {
                        rows_affected: result.rows_affected,
                        rolled_back: true,
                    })
                } else {
                    let result = conn
                        .execute_controlled(&sql, &control)
                        .await
                        .map_err(|e| e.to_string())?;
                    Ok(WriteOutcome::Committed {
                        rows_affected: result.rows_affected,
                    })
                }
            })
        })
        .await
    }
}

#[derive(Debug, Clone)]
pub struct TableSchema {
    pub columns: Vec<ColumnInfo>,
    pub indexes: Vec<IndexInfo>,
    pub foreign_keys: Vec<ForeignKeyInfo>,
}

#[derive(Debug, Clone)]
pub enum WriteOutcome {
    Preview { rows_affected: u64, rolled_back: bool },
    Committed { rows_affected: u64 },
}

fn validated_identifier(name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("identifier must not be empty".into());
    }
    if trimmed.len() > MAX_IDENTIFIER_BYTES {
        return Err(format!("identifier exceeds {MAX_IDENTIFIER_BYTES} bytes"));
    }
    if trimmed.chars().any(char::is_control) {
        return Err("identifier must not contain control characters".into());
    }
    Ok(trimmed.to_string())
}

fn count_statement(driver_id: &str, schema: Option<&str>, table: &str) -> Result<String, String> {
    let table = quote_ident(driver_id, &validated_identifier(table)?);
    let target = match schema {
        Some(schema) => format!("{}.{}", quote_ident(driver_id, &validated_identifier(schema)?), table),
        None => table,
    };
    Ok(format!("SELECT COUNT(*) AS row_count FROM {target}"))
}

fn count_from_value(value: &Value) -> Result<u64, String> {
    match value {
        Value::Int(count) if *count >= 0 => Ok(*count as u64),
        Value::Decimal(count) => count
            .to_string()
            .parse::<u64>()
            .map_err(|_| "the engine returned a count this tool cannot read".to_string()),
        _ => Err("the engine returned a count this tool cannot read".into()),
    }
}

async fn run_bounded<T, F>(operation: F, control: &OperationControl) -> Result<T, DriverError>
where
    F: Future<Output = T>,
{
    check_pre_dispatch(control)?;
    match control.deadline() {
        Some(deadline) => {
            tokio::select! {
                biased;
                _ = control.cancellation_token().cancelled() => Err(DriverError::Cancelled),
                _ = tokio::time::sleep_until(deadline) => Err(DriverError::TimedOut),
                result = operation => Ok(result),
            }
        }
        None => {
            tokio::select! {
                biased;
                _ = control.cancellation_token().cancelled() => Err(DriverError::Cancelled),
                result = operation => Ok(result),
            }
        }
    }
}

fn operation_control(cancellation: CancellationToken, timeout_secs: u64) -> OperationControl {
    operation_control_for(cancellation, Duration::from_secs(timeout_secs))
}

fn operation_control_for(cancellation: CancellationToken, timeout: Duration) -> OperationControl {
    OperationControl::new(cancellation, Some(Instant::now() + timeout))
}

fn sql_looks_like_write(sql: &str, driver_id: &str) -> bool {
    let facts = tablepro_policy::classify(sql, driver_id);
    facts.writes()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::{McpBridge, McpLimits, count_from_value, count_statement, sql_looks_like_write, validated_identifier};
    use crate::tokens::TokenStore;
    use tablepro_core::Value;

    struct NoProvider;

    #[async_trait::async_trait]
    impl super::ConnectionProvider for NoProvider {
        async fn list_saved_connections(&self) -> Result<Vec<tablepro_storage::SavedConnection>, String> {
            Ok(Vec::new())
        }
        async fn connection(
            &self,
            _connection_id: uuid::Uuid,
            _principal: tablepro_policy::Principal,
        ) -> Result<Arc<dyn tablepro_core::Connection>, String> {
            Err("no connections in this test".into())
        }
    }

    #[test]
    fn bridge_shutdown_cancels_every_owned_operation_control() {
        let dir = tempfile::tempdir().unwrap();
        let tokens = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
        let shutdown = tokio_util::sync::CancellationToken::new();
        let bridge = McpBridge::with_shutdown_token(Arc::new(NoProvider), tokens, shutdown);
        let control = bridge.operation_control();

        bridge.shutdown();

        assert!(control.cancellation_token().is_cancelled());
        assert!(bridge.operation_control().cancellation_token().is_cancelled());
    }

    /// H-adjacent finding: a failed authenticate never resolves to a token
    /// id, so it never reached the per-token rate limiter and could be
    /// retried without bound, each attempt taking the token store's
    /// cross-process file lock.
    #[test]
    fn repeated_failed_authentication_is_rate_limited_even_with_no_valid_token() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(TokenStore::open(dir.path().join("tokens.json")).unwrap());
        let bridge = McpBridge::with_limits(
            Arc::new(NoProvider),
            store,
            McpLimits {
                requests_per_minute: 2,
                ..McpLimits::default()
            },
        );

        assert!(bridge.authenticate("guess-1").is_err());
        assert!(bridge.authenticate("guess-2").is_err());
        let third = bridge.authenticate("guess-3").unwrap_err();
        assert!(third.contains("rate limit"), "{third}");
    }

    #[test]
    fn a_count_statement_quotes_the_target_for_the_engine() {
        assert_eq!(
            count_statement("postgres", Some("public"), "items").unwrap(),
            "SELECT COUNT(*) AS row_count FROM \"public\".\"items\""
        );
        assert_eq!(
            count_statement("mysql", None, "items").unwrap(),
            "SELECT COUNT(*) AS row_count FROM `items`"
        );
        assert_eq!(
            count_statement("mssql", None, "it]ems").unwrap(),
            "SELECT COUNT(*) AS row_count FROM [it]]ems]"
        );
    }

    #[test]
    fn a_hostile_identifier_cannot_escape_its_quotes() {
        let sql = count_statement("postgres", None, "items\"; TRUNCATE users --").unwrap();
        assert_eq!(
            sql,
            "SELECT COUNT(*) AS row_count FROM \"items\"\"; TRUNCATE users --\""
        );
        assert!(validated_identifier("").is_err());
        assert!(validated_identifier("  ").is_err());
        assert!(validated_identifier("items\nitems").is_err());
        assert!(validated_identifier("items\0").is_err());
        assert!(validated_identifier(&"x".repeat(1024)).is_err());
    }

    #[test]
    fn only_a_non_negative_integer_count_is_accepted() {
        assert_eq!(count_from_value(&Value::Int(7)).unwrap(), 7);
        assert_eq!(count_from_value(&Value::Decimal(12.into())).unwrap(), 12);
        assert!(count_from_value(&Value::Int(-1)).is_err());
        assert!(count_from_value(&Value::Text("7".into())).is_err());
        assert!(count_from_value(&Value::Null).is_err());
    }

    #[test]
    fn the_default_limits_are_the_values_the_bridge_has_always_used() {
        let limits = McpLimits::default();
        assert_eq!(limits.requests_per_minute, 120);
        assert_eq!(limits.max_rows, 500);
        assert_eq!(limits.query_timeout_secs, 30);
    }

    #[test]
    fn only_a_provable_read_skips_the_write_scope_check() {
        for sql in ["SELECT 1", "SELECT id FROM t WHERE id = 1"] {
            assert!(!sql_looks_like_write(sql, "postgres"), "{sql}");
        }
        for sql in [
            "DELETE FROM t WHERE id = 1",
            "CREATE TABLE t (id int)",
            "SELECT pg_read_file('/etc/passwd')",
            "COPY t TO PROGRAM 'sh'",
            "this is not sql at all",
            "",
        ] {
            assert!(sql_looks_like_write(sql, "postgres"), "{sql}");
        }
    }
}
