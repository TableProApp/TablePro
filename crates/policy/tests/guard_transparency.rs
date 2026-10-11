#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! The guard adds policy, not a driver. Properties that belong to the
//! connection underneath have to survive being wrapped, because the
//! interface only ever holds guarded connections: anything the guard
//! fails to forward is invisible to the whole application.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ColumnInfo, Connection, DriverError, Environment, ExecResult, OperationControl, QueryResult, QueryResultBatch,
    TableInfo, Value,
};
use tablepro_policy::{
    AuditError, AuditEvent, AuditSink, AuditState, DenyApprovalSink, GuardContext, NullAuditSink, PolicyConfig,
    PolicyGuard, Principal,
};
use uuid::Uuid;

struct AcceptingAudit;

#[async_trait]
impl AuditSink for AcceptingAudit {
    async fn record(&self, _event: AuditEvent) -> Result<(), AuditError> {
        Ok(())
    }
}

struct StubConnection {
    server_cancellation: bool,
}

#[async_trait]
impl Connection for StubConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        _table: &str,
        _offset: u64,
        _limit: u64,
    ) -> Result<QueryResult, DriverError> {
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    async fn query_result_sets_controlled(
        &self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        let sensitive = |name: &str, value: &str| QueryResult {
            columns: vec![ColumnInfo {
                name: name.into(),
                data_type: "text".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Text(value.into())]],
            truncated: false,
        };
        let result_sets = if sql.contains("json_agg") {
            vec![sensitive("payload", r#"{"pan":"4111111111111111"}"#)]
        } else {
            vec![
                sensitive("password", "first-secret"),
                sensitive("api_token", "second-secret"),
            ]
        };
        Ok(QueryResultBatch {
            result_sets,
            truncated: false,
        })
    }

    async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 0 })
    }

    async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 0 })
    }

    async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(Vec::new())
    }

    fn supports_server_cancellation(&self) -> bool {
        self.server_cancellation
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

fn guard_over(server_cancellation: bool) -> PolicyGuard {
    let inner: Arc<dyn Connection> = Arc::new(StubConnection { server_cancellation });
    let policy = PolicyConfig::default();
    let context = GuardContext {
        connection_id: Uuid::new_v4(),
        connection_name: "stub".into(),
        driver_id: "postgres".into(),
        environment: Environment::Local,
        read_only: false,
        principal: Principal::Human {
            session: "test-session".into(),
        },
        policy: Arc::new(policy),
        approval: Arc::new(DenyApprovalSink),
        audit: Arc::new(NullAuditSink),
        audit_state: Arc::new(AuditState::new()),
    };
    PolicyGuard::new(inner, context)
}

#[test]
fn a_guard_reports_the_server_cancellation_its_driver_supports() {
    assert!(
        guard_over(true).supports_server_cancellation(),
        "a guard hiding a driver's cancellation support would make Stop look impossible everywhere"
    );
}

#[test]
fn a_guard_does_not_invent_server_cancellation_the_driver_lacks() {
    assert!(!guard_over(false).supports_server_cancellation());
}

#[tokio::test]
async fn an_agent_guard_masks_sensitive_columns_in_every_result_set() {
    use tablepro_policy::{AutoApproveSink, Principal};
    use tokio_util::sync::CancellationToken;

    let inner: Arc<dyn Connection> = Arc::new(StubConnection {
        server_cancellation: false,
    });
    let guard = PolicyGuard::new(
        inner,
        GuardContext {
            connection_id: Uuid::new_v4(),
            connection_name: "multi-result mask test".into(),
            driver_id: "postgres".into(),
            environment: Environment::Prod,
            read_only: false,
            principal: Principal::Agent {
                token: "test-token".into(),
                client: None,
                model: None,
            },
            policy: Arc::new(PolicyConfig::default()),
            approval: Arc::new(AutoApproveSink),
            audit: Arc::new(AcceptingAudit),
            audit_state: Arc::new(AuditState::new()),
        },
    );
    let result = guard
        .query_result_sets_controlled("SELECT 1", &[], &OperationControl::new(CancellationToken::new(), None))
        .await
        .unwrap();

    assert_eq!(result.result_sets.len(), 2);
    assert_eq!(result.result_sets[0].rows[0][0], Value::Text("***REDACTED***".into()));
    assert_eq!(result.result_sets[1].rows[0][0], Value::Text("***REDACTED***".into()));
}

#[tokio::test]
async fn an_agent_guard_masks_json_aggregates_that_serialize_a_record() {
    use tablepro_policy::{AutoApproveSink, Principal};
    use tokio_util::sync::CancellationToken;

    let inner: Arc<dyn Connection> = Arc::new(StubConnection {
        server_cancellation: false,
    });
    let guard = PolicyGuard::new(
        inner,
        GuardContext {
            connection_id: Uuid::new_v4(),
            connection_name: "json aggregate mask test".into(),
            driver_id: "postgres".into(),
            environment: Environment::Prod,
            read_only: false,
            principal: Principal::Agent {
                token: "test-token".into(),
                client: None,
                model: None,
            },
            policy: Arc::new(PolicyConfig::default()),
            approval: Arc::new(AutoApproveSink),
            audit: Arc::new(AcceptingAudit),
            audit_state: Arc::new(AuditState::new()),
        },
    );
    let result = guard
        .query_result_sets_controlled(
            "SELECT json_agg(c) FROM cards c",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .unwrap();

    assert_eq!(result.result_sets[0].rows[0][0], Value::Text("***REDACTED***".into()));
}
