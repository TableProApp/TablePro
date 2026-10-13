use super::*;

struct ServerLikeConn {
    count_queries: Arc<AtomicUsize>,
    executed: Arc<AtomicUsize>,
}

#[async_trait]
impl Connection for ServerLikeConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        self.count_queries.fetch_add(1, Ordering::SeqCst);
        if sql.contains('$') {
            return Err(query_error());
        }
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.executed.fetch_add(statements.len(), Ordering::SeqCst);
        Ok(vec![1; statements.len()])
    }

    async fn execute_in_transaction_checked(
        &self,
        statements: &[(String, Vec<Value>)],
        _expect_one: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        self.executed.fetch_add(statements.len(), Ordering::SeqCst);
        Ok(vec![1; statements.len()])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported("begin".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct Fixture {
    guard: PolicyGuard,
    approvals: Arc<AtomicUsize>,
    count_queries: Arc<AtomicUsize>,
    executed: Arc<AtomicUsize>,
}

struct WaitingApproval {
    started: Arc<tokio::sync::Notify>,
    cancellation: Arc<std::sync::Mutex<Option<tokio_util::sync::CancellationToken>>>,
}

#[async_trait]
impl ApprovalSink for WaitingApproval {
    async fn request(&self, request: ApprovalRequest) -> ApprovalOutcome {
        *self.cancellation.lock().expect("approval cancellation lock") = request.cancellation;
        self.started.notify_one();
        std::future::pending().await
    }
}

fn fixture(max_rows: u64) -> Fixture {
    let approvals = Arc::new(AtomicUsize::new(0));
    let count_queries = Arc::new(AtomicUsize::new(0));
    let executed = Arc::new(AtomicUsize::new(0));
    let mut policy = PolicyConfig::default();
    policy
        .environments
        .entry("local".into())
        .or_default()
        .blast_radius_max_rows = Some(max_rows);
    let guard = PolicyGuard::new(
        Arc::new(ServerLikeConn {
            count_queries: count_queries.clone(),
            executed: executed.clone(),
        }),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );
    Fixture {
        guard,
        approvals,
        count_queries,
        executed,
    }
}

fn keyed_update(id: i64) -> (String, Vec<Value>) {
    (
        "UPDATE \"public\".\"people\" SET \"name\" = $1 WHERE \"id\" = $2 AND \"name\" IS NOT DISTINCT FROM $3".into(),
        vec![Value::Text("new".into()), Value::Int(id), Value::Text("old".into())],
    )
}

fn keyed_delete(id: i64) -> (String, Vec<Value>) {
    (
        "DELETE FROM \"public\".\"people\" WHERE \"id\" = $1".into(),
        vec![Value::Int(id)],
    )
}

#[tokio::test]
async fn a_checked_batch_of_keyed_writes_needs_no_count_query_and_no_approval() {
    let fixture = fixture(10_000);
    let statements = vec![keyed_update(1), keyed_delete(2)];

    fixture
        .guard
        .execute_in_transaction_checked(&statements, &[0, 1])
        .await
        .expect("a single-row keyed write is within the blast radius");

    assert_eq!(fixture.approvals.load(Ordering::SeqCst), 0);
    assert_eq!(fixture.count_queries.load(Ordering::SeqCst), 0);
    assert_eq!(fixture.executed.load(Ordering::SeqCst), 2);
}

fn controlled_approval_guard(
    started: Arc<tokio::sync::Notify>,
    cancellation: Arc<std::sync::Mutex<Option<tokio_util::sync::CancellationToken>>>,
    executed: Arc<AtomicUsize>,
    audit: Arc<SequenceAuditSink>,
) -> PolicyGuard {
    let mut policy = PolicyConfig::default();
    policy
        .environments
        .entry("local".into())
        .or_default()
        .human_approve_writes = Some(true);
    PolicyGuard::new(
        Arc::new(ServerLikeConn {
            count_queries: Arc::new(AtomicUsize::new(0)),
            executed,
        }),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(WaitingApproval { started, cancellation }),
            audit,
            Arc::new(AuditState::new()),
        ),
    )
}

async fn verify_controlled_approval_interruption(checked: bool, timed_out: bool) {
    let started = Arc::new(tokio::sync::Notify::new());
    let approval_cancellation = Arc::new(std::sync::Mutex::new(None));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let executed = Arc::new(AtomicUsize::new(0));
    let guard = controlled_approval_guard(
        started.clone(),
        approval_cancellation.clone(),
        executed.clone(),
        audit.clone(),
    );
    let cancellation = tokio_util::sync::CancellationToken::new();
    let control = if timed_out {
        OperationControl::with_timeout(std::time::Duration::from_millis(100))
    } else {
        OperationControl::new(cancellation.clone(), None)
    };
    let statements = vec![keyed_update(1)];
    let operation = tokio::spawn(async move {
        if checked {
            guard
                .execute_in_transaction_checked_controlled(&statements, &[0], &control)
                .await
        } else {
            guard.execute_in_transaction_controlled(&statements, &control).await
        }
    });
    tokio::time::timeout(std::time::Duration::from_secs(2), started.notified())
        .await
        .expect("approval request should start");
    if !timed_out {
        cancellation.cancel();
    }
    let error = operation
        .await
        .expect("operation task should complete")
        .expect_err("approval wait is interrupted");
    assert!(matches!(
        (timed_out, error),
        (true, DriverError::TimedOut) | (false, DriverError::Cancelled)
    ));
    assert_eq!(executed.load(Ordering::SeqCst), 0);
    assert!(
        approval_cancellation
            .lock()
            .expect("approval cancellation lock")
            .as_ref()
            .is_some_and(tokio_util::sync::CancellationToken::is_cancelled)
    );
    assert_interruption_audit(&audit, timed_out);
}

fn assert_interruption_audit(audit: &SequenceAuditSink, timed_out: bool) {
    let events = audit.events.lock().expect("audit events");
    let event = events.last().expect("terminal audit outcome");
    assert_eq!(event.phase, AuditRecordPhase::Outcome);
    assert_eq!(
        event.terminal_status,
        if timed_out {
            AuditTerminalStatus::TimedOut
        } else {
            AuditTerminalStatus::Cancelled
        }
    );
    assert_eq!(
        event.approval_outcome,
        if timed_out {
            AuditApprovalOutcome::TimedOut
        } else {
            AuditApprovalOutcome::Cancelled
        }
    );
}

#[tokio::test]
async fn controlled_transaction_approval_cancellation_is_audited() {
    verify_controlled_approval_interruption(false, false).await;
    verify_controlled_approval_interruption(true, false).await;
}

#[tokio::test]
async fn controlled_transaction_approval_timeout_is_audited() {
    verify_controlled_approval_interruption(false, true).await;
    verify_controlled_approval_interruption(true, true).await;
}

#[tokio::test]
async fn known_inserts_and_checked_writes_are_bounded_together() {
    let fixture = fixture(10_000);
    let statements = vec![
        ("INSERT INTO people (id, name) VALUES (9, 'x')".into(), vec![]),
        keyed_update(1),
    ];

    fixture
        .guard
        .execute_in_transaction_checked(&statements, &[1])
        .await
        .expect("insert plus checked update");

    assert_eq!(fixture.approvals.load(Ordering::SeqCst), 0);
    assert_eq!(fixture.count_queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_checked_batch_over_the_row_limit_still_asks_for_approval() {
    let fixture = fixture(2);
    let statements = vec![keyed_update(1), keyed_update(2), keyed_update(3)];

    fixture
        .guard
        .execute_in_transaction_checked(&statements, &[0, 1, 2])
        .await
        .expect("approved after the prompt");

    assert_eq!(fixture.approvals.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_write_the_driver_does_not_check_still_asks_for_approval() {
    let fixture = fixture(10_000);
    let statements = vec![keyed_update(1), keyed_delete(2)];

    fixture
        .guard
        .execute_in_transaction_checked(&statements, &[0])
        .await
        .expect("approved after the prompt");

    assert_eq!(
        fixture.approvals.load(Ordering::SeqCst),
        1,
        "an unchecked delete has an unknown blast radius"
    );
}

#[tokio::test]
async fn an_unchecked_parameterized_batch_stays_fail_closed() {
    let fixture = fixture(10_000);

    fixture
        .guard
        .execute_in_transaction(&[keyed_update(1)])
        .await
        .expect("approved after the prompt");

    assert_eq!(fixture.approvals.load(Ordering::SeqCst), 1);
}
