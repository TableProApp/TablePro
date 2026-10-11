use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use tokio::sync::Notify;

use crate::catalog::{CatalogObject, CatalogObjectKind};
use crate::error::DriverError;
use crate::operation::{OperationControl, run_controlled};
use crate::query::{
    ColumnInfo, ExecResult, ForeignKeyInfo, IndexInfo, QueryResult, QueryResultBatch, TableInfo, Value,
};
use crate::tls::TlsConfig;
use crate::transaction::Transaction;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMode {
    #[default]
    Password,
    Kerberos,
}

#[derive(Debug, Clone)]
pub struct ConnectOptions {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub password: SecretString,
    pub tls: TlsConfig,
    pub auth_mode: AuthMode,
    pub service_endpoint: Option<(String, u16)>,
    /// Direct local Unix-domain socket directory selected by the user.
    /// This remains distinct from SSH-created forwarding sockets.
    pub local_socket_dir: Option<PathBuf>,
    pub forwarded_socket_dir: Option<PathBuf>,
    pub application_name: Option<String>,
    pub connect_timeout_secs: Option<u32>,
    pub read_only: bool,
}

impl ConnectOptions {
    pub fn service_address(&self) -> (&str, u16) {
        self.service_endpoint
            .as_ref()
            .map_or((self.host.as_str(), self.port), |(host, port)| (host.as_str(), *port))
    }

    pub fn transport(&self) -> Transport<'_> {
        match (&self.forwarded_socket_dir, &self.local_socket_dir) {
            (Some(dir), _) => {
                let (host, port) = self.service_address();
                Transport::Socket {
                    directory: dir.as_path(),
                    identity_host: host,
                    identity_port: port,
                    origin: SocketOrigin::Forwarded,
                }
            }
            (None, Some(dir)) => Transport::Socket {
                directory: dir.as_path(),
                identity_host: self.host.as_str(),
                identity_port: self.port,
                origin: SocketOrigin::Local,
            },
            (None, None) => Transport::Tcp {
                host: self.host.as_str(),
                port: self.port,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport<'a> {
    Tcp {
        host: &'a str,
        port: u16,
    },
    Socket {
        directory: &'a Path,
        identity_host: &'a str,
        identity_port: u16,
        origin: SocketOrigin,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SocketOrigin {
    Local,
    Forwarded,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            host: "localhost".to_string(),
            port: 0,
            database: String::new(),
            username: String::new(),
            password: SecretString::new(String::new().into()),
            tls: TlsConfig::disabled(),
            auth_mode: AuthMode::Password,
            service_endpoint: None,
            local_socket_dir: None,
            forwarded_socket_dir: None,
            application_name: None,
            connect_timeout_secs: None,
            read_only: false,
        }
    }
}

#[async_trait]
pub trait Connection: Send + Sync {
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        Err(DriverError::Unsupported("listing databases".into()))
    }
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError>;
    async fn list_tables_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        run_controlled(self.list_tables(), control).await
    }
    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(Vec::new())
    }
    async fn list_views_controlled(&self, control: &OperationControl) -> Result<Vec<TableInfo>, DriverError> {
        run_controlled(self.list_views(), control).await
    }
    async fn open_session(&self) -> Result<Box<dyn crate::Session>, DriverError> {
        Err(DriverError::Unsupported("dedicated sessions".into()))
    }
    async fn list_objects(
        &self,
        kind: CatalogObjectKind,
        _schema: Option<&str>,
    ) -> Result<Vec<CatalogObject>, DriverError> {
        Err(DriverError::Unsupported(format!("listing {} objects", kind.as_str())))
    }
    async fn list_objects_controlled(
        &self,
        kind: CatalogObjectKind,
        schema: Option<&str>,
        control: &OperationControl,
    ) -> Result<Vec<CatalogObject>, DriverError> {
        run_controlled(self.list_objects(kind, schema), control).await
    }
    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError>;
    async fn fetch_columns_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ColumnInfo>, DriverError> {
        run_controlled(self.fetch_columns(schema, table), control).await
    }
    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError>;
    async fn fetch_rows_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        run_controlled(self.fetch_rows(schema, table, offset, limit), control).await
    }
    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError>;
    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        run_controlled(self.query(sql), control).await
    }
    /// Parameterised SELECT. Bound `Value`s are passed through to the
    /// driver's prepare/bind path (sqlx::query::bind for the built-in
    /// drivers). Default impl delegates to `query` when params is
    /// empty, so legacy callers compile unchanged; drivers that
    /// support real parameter binding override.
    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            self.query(sql).await
        } else {
            Err(DriverError::Internal(
                "query_params is not implemented for this driver".into(),
            ))
        }
    }
    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        run_controlled(self.query_params(sql, params), control).await
    }
    /// Run a query and preserve each tabular result set in order, including
    /// empty sets. Drivers without multi-set results inherit single-result behavior.
    async fn query_result_sets_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        let result = if params.is_empty() {
            self.query_controlled(sql, control).await
        } else {
            self.query_params_controlled(sql, params, control).await
        }?;
        Ok(QueryResultBatch::single(result))
    }
    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError>;
    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        run_controlled(self.execute(sql), control).await
    }
    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError>;
    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        run_controlled(self.execute_params(sql, params), control).await
    }
    /// Run a sequence of parameterised statements inside a single
    /// database transaction. Rolls back automatically if any
    /// statement errors; returns `DriverError::Transaction` with the
    /// failing statement's index after the rollback request succeeds,
    /// or `DriverError::TransactionRollbackFailed` if rollback also
    /// errors. Atomicity still depends on the database and affected
    /// storage objects; this API cannot make non-transactional tables
    /// transactional. Returns one `rows_affected` value per successful
    /// statement, in order. Used by the inline-edit changeset Save flow.
    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError>;
    async fn execute_in_transaction_checked(
        &self,
        statements: &[(String, Vec<Value>)],
        expect_one: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        if expect_one.is_empty() {
            return self.execute_in_transaction(statements).await;
        }
        Err(DriverError::Unsupported("checked transaction writes".into()))
    }
    /// Bounded form of [`Connection::execute_in_transaction`]. The
    /// default drops the transaction future on an interruption, which
    /// rolls the transaction back but cannot prove it did, so the
    /// outcome is reported unknown. A driver that can confirm the
    /// rollback should override this.
    async fn execute_in_transaction_controlled(
        &self,
        statements: &[(String, Vec<Value>)],
        control: &OperationControl,
    ) -> Result<Vec<u64>, DriverError> {
        run_controlled(self.execute_in_transaction(statements), control).await
    }
    async fn execute_in_transaction_checked_controlled(
        &self,
        statements: &[(String, Vec<Value>)],
        expect_one: &[usize],
        control: &OperationControl,
    ) -> Result<Vec<u64>, DriverError> {
        if expect_one.is_empty() {
            return self.execute_in_transaction_controlled(statements, control).await;
        }
        run_controlled(self.execute_in_transaction_checked(statements, expect_one), control).await
    }
    /// Indexes defined on `table`. Implementations may include the
    /// implicit primary-key index with `primary = true` so the UI can
    /// render it as read-only. The default answers with an empty list,
    /// which says nothing about whether the engine has indexes at all:
    /// `DatabaseDriver::supports_index_metadata` is what tells a caller
    /// whether this list can be trusted as "none".
    async fn fetch_indexes(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Ok(Vec::new())
    }
    async fn fetch_indexes_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<IndexInfo>, DriverError> {
        run_controlled(self.fetch_indexes(schema, table), control).await
    }
    /// Foreign-key constraints declared on `table`. Empty carries the
    /// same ambiguity as `fetch_indexes`; read
    /// `DatabaseDriver::supports_foreign_key_metadata` alongside it.
    async fn fetch_foreign_keys(
        &self,
        _schema: Option<&str>,
        _table: &str,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Ok(Vec::new())
    }
    async fn fetch_foreign_keys_controlled(
        &self,
        schema: Option<&str>,
        table: &str,
        control: &OperationControl,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        run_controlled(self.fetch_foreign_keys(schema, table), control).await
    }
    /// Open an interactive transaction for preview-then-commit flows.
    /// Default returns `Unsupported` so drivers adopt incrementally.
    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported(
            "begin is not implemented for this driver".into(),
        ))
    }
    /// Best-effort server version string (e.g. `PostgreSQL 16.3`). Default
    /// returns `None` when the driver has not implemented detection.
    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        Ok(None)
    }
    /// Whether an interrupted `*_controlled` call asks the server to
    /// stop the statement. When false the driver can only drop its own
    /// future, so the statement may still be running and the outcome is
    /// unknown; callers must not offer a Stop that cannot stop.
    fn supports_server_cancellation(&self) -> bool {
        false
    }
    /// Receives the `Notify` the connection monitor already waits on.
    /// A driver that retires its connection without returning
    /// [`DriverError::Disconnected`] wakes that same sink from the retirement.
    fn attach_fault_notify(&self, _notify: Arc<Notify>) {}
    async fn ping(&self) -> Result<(), DriverError>;
    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}

#[cfg(test)]
mod controlled_default_tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use tokio_util::sync::CancellationToken;

    use super::*;

    #[derive(Default)]
    struct SlowConnection {
        dispatched: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl Connection for SlowConnection {
        async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
            self.stall().await
        }

        async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
            self.stall().await
        }

        async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
            self.stall().await
        }

        async fn fetch_indexes(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<IndexInfo>, DriverError> {
            self.stall().await
        }

        async fn fetch_foreign_keys(
            &self,
            _schema: Option<&str>,
            _table: &str,
        ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
            self.stall().await
        }

        async fn fetch_rows(
            &self,
            _schema: Option<&str>,
            _table: &str,
            _offset: u64,
            _limit: u64,
        ) -> Result<QueryResult, DriverError> {
            self.stall().await
        }

        async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
            self.stall().await
        }

        async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
            self.stall().await
        }

        async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
            self.stall().await
        }

        async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
            self.stall().await
        }

        async fn ping(&self) -> Result<(), DriverError> {
            Ok(())
        }

        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    impl SlowConnection {
        async fn stall<T>(&self) -> Result<T, DriverError> {
            self.dispatched.fetch_add(1, Ordering::SeqCst);
            std::future::pending().await
        }
    }

    fn cancelled_control() -> OperationControl {
        let token = CancellationToken::new();
        token.cancel();
        OperationControl::new(token, None)
    }

    fn expired_control() -> OperationControl {
        OperationControl::new(
            CancellationToken::new(),
            Some(tokio::time::Instant::now() - Duration::from_millis(1)),
        )
    }

    #[tokio::test]
    async fn a_cancelled_control_stops_every_metadata_read_before_dispatch() {
        let dispatched = Arc::new(AtomicUsize::new(0));
        let connection = SlowConnection {
            dispatched: dispatched.clone(),
        };
        let control = cancelled_control();

        assert!(matches!(
            connection.list_tables_controlled(&control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.list_views_controlled(&control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_columns_controlled(None, "t", &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_indexes_controlled(None, "t", &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_foreign_keys_controlled(None, "t", &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_rows_controlled(None, "t", 0, 10, &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_indexes_controlled(None, "t", &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.fetch_foreign_keys_controlled(None, "t", &control).await,
            Err(DriverError::Cancelled)
        ));
        assert!(matches!(
            connection.execute_in_transaction_controlled(&[], &control).await,
            Err(DriverError::Cancelled)
        ));
        assert_eq!(
            dispatched.load(Ordering::SeqCst),
            0,
            "a cancelled control must never reach the database"
        );
    }

    #[tokio::test]
    async fn an_expired_deadline_stops_every_metadata_read_before_dispatch() {
        let dispatched = Arc::new(AtomicUsize::new(0));
        let connection = SlowConnection {
            dispatched: dispatched.clone(),
        };
        let control = expired_control();

        assert!(matches!(
            connection.list_tables_controlled(&control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_columns_controlled(None, "t", &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_indexes_controlled(None, "t", &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_foreign_keys_controlled(None, "t", &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_rows_controlled(None, "t", 0, 10, &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_indexes_controlled(None, "t", &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.fetch_foreign_keys_controlled(None, "t", &control).await,
            Err(DriverError::TimedOut)
        ));
        assert!(matches!(
            connection.execute_in_transaction_controlled(&[], &control).await,
            Err(DriverError::TimedOut)
        ));
        assert_eq!(dispatched.load(Ordering::SeqCst), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn a_deadline_reached_mid_flight_reports_an_unknown_outcome() {
        let connection = SlowConnection::default();
        let control = OperationControl::new(
            CancellationToken::new(),
            Some(tokio::time::Instant::now() + Duration::from_secs(5)),
        );

        let error = connection
            .execute_in_transaction_controlled(&[("UPDATE t SET a = 1".into(), Vec::new())], &control)
            .await
            .expect_err("a stalled transaction must not report success");
        assert!(
            matches!(error, DriverError::OperationOutcomeUnknown { .. }),
            "an abandoned transaction cannot prove it rolled back: {error:?}"
        );
    }

    #[tokio::test]
    async fn a_driver_declares_no_server_cancellation_by_default() {
        let connection = SlowConnection::default();
        assert!(!connection.supports_server_cancellation());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_address_uses_dial_endpoint_for_direct_connections() {
        let options = ConnectOptions {
            host: "sql.corp.example".into(),
            port: 1433,
            ..Default::default()
        };

        assert_eq!(options.service_address(), ("sql.corp.example", 1433));
    }

    #[test]
    fn transport_uses_the_dial_address_without_socket_forwarding() {
        let options = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 54321,
            service_endpoint: Some(("db.corp.example".into(), 5432)),
            ..Default::default()
        };

        assert_eq!(
            options.transport(),
            Transport::Tcp {
                host: "127.0.0.1",
                port: 54321
            }
        );
    }

    #[test]
    fn transport_presents_service_identity_over_a_forwarded_socket() {
        let options = ConnectOptions {
            host: "db.corp.example".into(),
            port: 5432,
            service_endpoint: Some(("db.corp.example".into(), 5432)),
            forwarded_socket_dir: Some(PathBuf::from("/run/user/1000/tablepro-ssh-abc")),
            ..Default::default()
        };

        assert_eq!(
            options.transport(),
            Transport::Socket {
                directory: Path::new("/run/user/1000/tablepro-ssh-abc"),
                identity_host: "db.corp.example",
                identity_port: 5432,
                origin: SocketOrigin::Forwarded,
            }
        );
    }

    #[test]
    fn transport_uses_a_distinct_local_socket_origin() {
        let options = ConnectOptions {
            host: "localhost".into(),
            port: 5432,
            local_socket_dir: Some(PathBuf::from("/run/postgresql")),
            ..Default::default()
        };

        assert_eq!(
            options.transport(),
            Transport::Socket {
                directory: Path::new("/run/postgresql"),
                identity_host: "localhost",
                identity_port: 5432,
                origin: SocketOrigin::Local,
            }
        );
    }

    #[test]
    fn service_address_preserves_service_identity_through_tunnels() {
        let options = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 54321,
            service_endpoint: Some(("sql.corp.example".into(), 1433)),
            ..Default::default()
        };

        assert_eq!(options.service_address(), ("sql.corp.example", 1433));
    }
}
