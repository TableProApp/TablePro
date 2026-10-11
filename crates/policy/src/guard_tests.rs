use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::sync::Notify;

use super::*;
use crate::approval::{ApprovalOutcome, ApprovalRequest, AutoApproveSink, DenyApprovalSink};
use crate::audit::NullAuditSink;

struct CountingTx {
    executes: Arc<AtomicUsize>,
    commits: Arc<AtomicUsize>,
}

#[async_trait]
impl Transaction for CountingTx {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        self.executes.fetch_add(1, Ordering::SeqCst);
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        self.commits.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct CountingConn {
    executes: Arc<AtomicUsize>,
    commits: Arc<AtomicUsize>,
}
struct BlockingWriteConn {
    dispatched: Arc<Notify>,
    release: Arc<Notify>,
}
struct AmbiguousWriteConn;
struct PanickingConn;
struct ControlledWriteConn {
    outcome_unknown: bool,
}
struct TransactionQueryErrorConn;
struct TransactionQueryErrorTx;
struct QueryCountingConn {
    queries: Arc<AtomicUsize>,
}
struct QueryCountingTx {
    queries: Arc<AtomicUsize>,
}
struct AmbiguousCommitTx;

#[async_trait]
impl Transaction for QueryCountingTx {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        self.queries.fetch_add(1, Ordering::SeqCst);
        Ok(empty_result())
    }

    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Transaction for TransactionQueryErrorTx {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        Err(query_error())
    }

    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        Err(query_error())
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Transaction for AmbiguousCommitTx {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        Err(DriverError::Disconnected)
    }

    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for CountingConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(QueryResult {
            columns: vec![],
            rows: vec![vec![Value::Int(1)]],
            truncated: false,
        })
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        self.executes.fetch_add(1, Ordering::SeqCst);
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.execute("").await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.executes.fetch_add(statements.len(), Ordering::SeqCst);
        Ok(vec![1; statements.len()])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Ok(Box::new(CountingTx {
            executes: self.executes.clone(),
            commits: self.commits.clone(),
        }))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for QueryCountingConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        self.queries.fetch_add(1, Ordering::SeqCst);
        Ok(QueryResult {
            columns: vec![],
            rows: vec![vec![Value::Int(1)]],
            truncated: false,
        })
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(vec![1])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Ok(Box::new(QueryCountingTx {
            queries: self.queries.clone(),
        }))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for TransactionQueryErrorConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Err(query_error())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(query_error())
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Err(query_error())
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(query_error())
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Ok(Box::new(TransactionQueryErrorTx))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for BlockingWriteConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        self.dispatched.notify_one();
        self.release.notified().await;
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, sql: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.execute(sql).await
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.execute("").await.map(|result| vec![result.rows_affected])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported("transaction".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for ControlledWriteConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query_controlled(&self, _: &str, _: &OperationControl) -> Result<QueryResult, DriverError> {
        if self.outcome_unknown {
            return Err(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::TimedOut),
            });
        }
        Err(DriverError::TimedOut)
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_controlled(&self, _: &str, _: &OperationControl) -> Result<ExecResult, DriverError> {
        if self.outcome_unknown {
            return Err(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::TimedOut),
            });
        }
        Err(DriverError::TimedOut)
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(vec![1])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported("transaction".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for AmbiguousWriteConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Tls("Bearer raw-driver-secret".into()))
    }

    async fn execute_params(&self, sql: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.execute(sql).await
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::Tls("Bearer raw-driver-secret".into()))
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Ok(Box::new(AmbiguousCommitTx))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct SequenceAuditSink {
    failures: Mutex<Vec<AuditRecordPhase>>,
    events: Mutex<Vec<AuditEvent>>,
}

impl SequenceAuditSink {
    fn new(failures: Vec<AuditRecordPhase>) -> Self {
        Self {
            failures: Mutex::new(failures),
            events: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait]
impl AuditSink for SequenceAuditSink {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        let mut failures = self.failures.lock().expect("failure lock");
        if failures.first() == Some(&event.phase) {
            failures.remove(0);
            return Err(AuditError::Persistence("injected failure".into()));
        }
        drop(failures);
        self.events.lock().expect("event lock").push(event);
        Ok(())
    }
}

struct CountingApprovalSink {
    calls: Arc<AtomicUsize>,
}

struct SequenceApprovalSink {
    calls: Arc<AtomicUsize>,
    outcomes: Mutex<Vec<ApprovalOutcome>>,
}

#[async_trait]
impl ApprovalSink for SequenceApprovalSink {
    async fn request(&self, _request: ApprovalRequest) -> ApprovalOutcome {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let mut outcomes = self.outcomes.lock().expect("outcome lock");
        if outcomes.is_empty() {
            return ApprovalOutcome::Deny;
        }
        outcomes.remove(0)
    }
}

#[async_trait]
impl ApprovalSink for CountingApprovalSink {
    async fn request(&self, _request: ApprovalRequest) -> ApprovalOutcome {
        self.calls.fetch_add(1, Ordering::SeqCst);
        ApprovalOutcome::AllowOnce
    }
}

fn query_error() -> DriverError {
    DriverError::Query {
        message: "injected query error".into(),
        sqlstate: Some("42000".into()),
        position: None,
    }
}

fn empty_result() -> QueryResult {
    QueryResult {
        columns: vec![],
        rows: vec![],
        truncated: false,
    }
}

fn context(
    principal: Principal,
    environment: Environment,
    policy: PolicyConfig,
    approval: Arc<dyn ApprovalSink>,
    audit: Arc<dyn AuditSink>,
    audit_state: Arc<AuditState>,
) -> GuardContext {
    GuardContext {
        connection_id: Uuid::nil(),
        connection_name: "test".into(),
        driver_id: "postgres".into(),
        environment,
        read_only: false,
        principal,
        policy: Arc::new(policy),
        approval,
        audit,
        audit_state,
    }
}

#[async_trait]
impl Connection for PanickingConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        panic!("codec read past the end of the buffer")
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        panic!("codec read past the end of the buffer")
    }

    async fn execute_params(&self, sql: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.execute(sql).await
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        panic!("codec read past the end of the buffer")
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct DisconnectedConn;

#[async_trait]
impl Connection for DisconnectedConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Err(DriverError::Disconnected)
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Disconnected)
    }

    async fn execute_params(&self, sql: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.execute(sql).await
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::Disconnected)
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

fn connection(executes: Arc<AtomicUsize>, commits: Arc<AtomicUsize>) -> Arc<dyn Connection> {
    Arc::new(CountingConn { executes, commits })
}

fn query_counting_connection(queries: Arc<AtomicUsize>) -> Arc<dyn Connection> {
    Arc::new(QueryCountingConn { queries })
}

fn allowed_agent_policy() -> PolicyConfig {
    let mut policy = PolicyConfig::default();
    let local = policy.environments.entry("local".into()).or_default();
    local.agent_writes = Some(crate::config::WritePolicy::Allow);
    local.agent_allow_multi_statement = Some(true);
    policy
}

#[path = "guard_tests_audit.rs"]
mod audit;
#[path = "guard_tests_bulk.rs"]
mod bulk;
#[path = "guard_tests_checked.rs"]
mod checked;
#[path = "guard_tests_gating.rs"]
mod gating;
#[path = "guard_tests_session.rs"]
mod session;
