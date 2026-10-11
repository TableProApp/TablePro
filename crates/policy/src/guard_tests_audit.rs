use super::*;

struct WaitingApproval {
    started: Arc<Notify>,
}

#[async_trait]
impl ApprovalSink for WaitingApproval {
    async fn request(&self, _request: ApprovalRequest) -> ApprovalOutcome {
        self.started.notify_one();
        std::future::pending().await
    }
}

fn gui_guard(connection: Arc<dyn Connection>, audit: Arc<SequenceAuditSink>, state: Arc<AuditState>) -> PolicyGuard {
    PolicyGuard::new(
        connection,
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit,
            state,
        ),
    )
}

#[test]
fn rollback_failure_is_audited_as_an_unknown_transaction_outcome() {
    let error = DriverError::TransactionRollbackFailed {
        statement_index: 1,
        source: Box::new(DriverError::Query {
            message: "statement failed".into(),
            sqlstate: None,
            position: None,
        }),
        rollback_error: Box::new(DriverError::Disconnected),
    };

    assert_eq!(
        super::super::transaction_error_outcome(&error),
        (AuditTerminalStatus::Unknown, AuditTransactionOutcome::Unknown, true)
    );
    assert_eq!(super::super::error_category(&error), AuditErrorCategory::Unknown);
}

#[test]
fn confirmed_transaction_rollback_is_not_audited_as_an_unknown_outcome() {
    let error = DriverError::Transaction {
        statement_index: 1,
        source: Box::new(DriverError::ConcurrentModification),
    };

    assert_eq!(
        super::super::transaction_error_outcome(&error),
        (AuditTerminalStatus::Failed, AuditTransactionOutcome::RolledBack, false)
    );
    assert_eq!(super::super::error_category(&error), AuditErrorCategory::Transaction);
}

#[tokio::test]
async fn post_execution_audit_failure_poisons_shared_state() {
    let executes = Arc::new(AtomicUsize::new(0));
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Outcome]));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let sibling = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit,
            state,
        ),
    );

    let first = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("outcome must fail");
    let second = sibling
        .execute("INSERT INTO jobs(id) VALUES (2)")
        .await
        .expect_err("shared state must remain poisoned");

    assert!(first.to_string().contains("operation may have succeeded"));
    assert!(second.to_string().contains("governed writes are disabled"));
    assert_eq!(executes.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cancelling_a_pending_approval_records_a_terminal_cancelled_outcome() {
    let started = Arc::new(Notify::new());
    let executions = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(executions.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(WaitingApproval {
                started: started.clone(),
            }),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );
    let cancellation = tokio_util::sync::CancellationToken::new();
    let control = OperationControl::new(cancellation.clone(), None);
    let operation = tokio::spawn(async move {
        guard
            .execute_controlled("CREATE PROCEDURE disconnected() SELECT 1", &control)
            .await
    });

    tokio::time::timeout(std::time::Duration::from_secs(5), started.notified())
        .await
        .expect("approval request should start");
    cancellation.cancel();

    assert!(matches!(
        operation.await.expect("guarded operation should finish"),
        Err(DriverError::Cancelled)
    ));
    assert_eq!(
        executions.load(Ordering::SeqCst),
        0,
        "cancelled approval must not execute SQL"
    );
    let events = audit.events.lock().expect("audit events");
    assert_eq!(events.len(), 1, "cancellation must have exactly one terminal event");
    assert_eq!(events[0].phase, AuditRecordPhase::Outcome);
    assert_eq!(events[0].terminal_status, AuditTerminalStatus::Cancelled);
    assert_eq!(events[0].approval_outcome, AuditApprovalOutcome::Denied);
    assert_eq!(events[0].error_category, Some(AuditErrorCategory::Cancelled));
}

#[tokio::test]
async fn dropped_write_future_poisons_shared_state() {
    let state = Arc::new(AuditState::new());
    let dispatched = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let guard = PolicyGuard::new(
        Arc::new(BlockingWriteConn {
            dispatched: dispatched.clone(),
            release,
        }),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            state.clone(),
        ),
    );

    let task = tokio::spawn(async move { guard.execute("INSERT INTO jobs(id) VALUES (1)").await });
    tokio::time::timeout(std::time::Duration::from_secs(5), dispatched.notified())
        .await
        .expect("the permitted write must reach the driver before it is aborted");
    task.abort();
    task.await.expect_err("write task must be cancelled");

    assert!(state.governed_writes_disabled());
}

#[tokio::test]
async fn abandoning_an_old_write_after_replacement_keeps_the_new_generation_writable() {
    let journal = AuditState::new();
    let old_state = Arc::new(journal.new_connection_generation());
    let dispatched = Arc::new(Notify::new());
    let pending_guard = gui_guard(
        Arc::new(BlockingWriteConn {
            dispatched: dispatched.clone(),
            release: Arc::new(Notify::new()),
        }),
        Arc::new(SequenceAuditSink::new(vec![])),
        old_state.clone(),
    );
    let pending = tokio::spawn(async move { pending_guard.execute("INSERT INTO jobs(id) VALUES (1)").await });
    tokio::time::timeout(std::time::Duration::from_secs(5), dispatched.notified())
        .await
        .expect("old write reached the driver");

    let replacement_state = Arc::new(old_state.new_connection_generation());
    pending.abort();
    pending.await.expect_err("old write was abandoned after replacement");
    assert!(old_state.governed_writes_disabled());
    assert!(!replacement_state.governed_writes_disabled());

    let old_executes = Arc::new(AtomicUsize::new(0));
    let old_guard = gui_guard(
        connection(old_executes.clone(), Arc::new(AtomicUsize::new(0))),
        Arc::new(SequenceAuditSink::new(vec![])),
        old_state,
    );
    old_guard
        .execute("INSERT INTO jobs(id) VALUES (2)")
        .await
        .expect_err("old generation refuses another write before dispatch");
    assert_eq!(old_executes.load(Ordering::SeqCst), 0);

    let new_executes = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let replacement = gui_guard(
        connection(new_executes.clone(), Arc::new(AtomicUsize::new(0))),
        audit.clone(),
        replacement_state,
    );
    replacement
        .execute("INSERT INTO jobs(id) VALUES (3)")
        .await
        .expect("replacement remains writable after the late old-generation failure");
    assert_eq!(new_executes.load(Ordering::SeqCst), 1);
    assert_eq!(
        audit.events.lock().unwrap().last().unwrap().terminal_status,
        AuditTerminalStatus::Succeeded
    );
}

#[tokio::test]
async fn batch_query_error_records_unknown_and_poisons_state() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(TransactionQueryErrorConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let statements = vec![("INSERT INTO jobs(id) VALUES (1)".into(), vec![])];

    guard
        .execute_in_transaction(&statements)
        .await
        .expect_err("batch query error must surface");

    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("batch outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.transaction_outcome, AuditTransactionOutcome::Unknown);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Query));
}

#[tokio::test]
async fn interactive_transaction_execute_query_error_records_unknown_and_poisons_state() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(TransactionQueryErrorConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let mut transaction = guard.begin().await.expect("begin");

    transaction
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("transaction query error must surface");

    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("transaction statement outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.transaction_outcome, AuditTransactionOutcome::Unknown);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Query));
}

#[tokio::test]
async fn confirmed_controlled_timeout_records_timeout_without_poisoning_state() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(ControlledWriteConn { outcome_unknown: false }),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let control = OperationControl::new(Default::default(), None);

    let error = guard
        .execute_controlled("INSERT INTO jobs(id) VALUES (1)", &control)
        .await
        .expect_err("confirmed timeout must surface");

    assert!(matches!(error, DriverError::TimedOut));
    assert!(!state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::TimedOut);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Timeout));
}

#[tokio::test]
async fn controlled_unknown_outcome_records_unknown_and_poisons_state() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(ControlledWriteConn { outcome_unknown: true }),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let control = OperationControl::new(Default::default(), None);

    let error = guard
        .execute_controlled("INSERT INTO jobs(id) VALUES (1)", &control)
        .await
        .expect_err("unknown outcome must surface");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Unknown));
}

#[tokio::test]
async fn an_unknown_write_blocks_only_its_connection_and_generation() {
    let journal = Arc::new(AuditState::new());
    let state_a = Arc::new(journal.new_connection_generation());
    let state_b = Arc::new(journal.new_connection_generation());
    let audit_a = Arc::new(SequenceAuditSink::new(vec![]));
    let guard_a = gui_guard(
        Arc::new(ControlledWriteConn { outcome_unknown: true }),
        audit_a.clone(),
        state_a.clone(),
    );
    let executes_b = Arc::new(AtomicUsize::new(0));
    let audit_b = Arc::new(SequenceAuditSink::new(vec![]));
    let guard_b = gui_guard(
        connection(executes_b.clone(), Arc::new(AtomicUsize::new(0))),
        audit_b.clone(),
        state_b.clone(),
    );

    guard_a
        .execute_controlled(
            "INSERT INTO jobs(id) VALUES (1)",
            &OperationControl::new(Default::default(), None),
        )
        .await
        .expect_err("uncertain write must surface");
    assert!(state_a.governed_writes_disabled());
    assert!(!state_b.governed_writes_disabled());
    assert_eq!(
        audit_a.events.lock().unwrap().last().unwrap().terminal_status,
        AuditTerminalStatus::Unknown
    );

    guard_b
        .execute("INSERT INTO jobs(id) VALUES (2)")
        .await
        .expect("another connection remains writable");
    assert_eq!(executes_b.load(Ordering::SeqCst), 1);
    assert_eq!(
        audit_b.events.lock().unwrap().last().unwrap().terminal_status,
        AuditTerminalStatus::Succeeded
    );

    let replacement_a_state = Arc::new(state_a.new_connection_generation());
    state_a.disable_governed_writes(); // A late failure from the retired generation.
    let audit_replacement = Arc::new(SequenceAuditSink::new(vec![]));
    let replacement_a = gui_guard(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        audit_replacement.clone(),
        replacement_a_state.clone(),
    );
    replacement_a
        .execute("INSERT INTO jobs(id) VALUES (3)")
        .await
        .expect("fresh connection generation restores writes");
    assert!(!replacement_a_state.governed_writes_disabled());
    assert_eq!(
        audit_replacement.events.lock().unwrap().last().unwrap().terminal_status,
        AuditTerminalStatus::Succeeded
    );
}

#[tokio::test]
async fn controlled_read_unknown_outcome_does_not_poison_governed_writes() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(ControlledWriteConn { outcome_unknown: true }),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let control = OperationControl::new(Default::default(), None);

    let error = guard
        .query_controlled("SELECT * FROM jobs", &control)
        .await
        .expect_err("unknown read outcome must surface");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(!state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Unknown));
}

#[tokio::test]
async fn ambiguous_driver_error_records_unknown_and_poisons_state() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(AmbiguousWriteConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("TLS error must surface");

    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.error_category, Some(AuditErrorCategory::Tls));
}

#[tokio::test]
async fn audit_events_sanitize_driver_details_and_agent_token() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(AmbiguousWriteConn),
        context(
            Principal::Agent {
                token: "Bearer raw-agent-token".into(),
                client: Some("review-test".into()),
                model: None,
            },
            Environment::Local,
            allowed_agent_policy(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("TLS error must surface");

    let events = audit.events.lock().expect("event lock");
    let serialized = serde_json::to_string(&*events).expect("serialize events");
    assert!(!serialized.contains("raw-agent-token"));
    assert!(!serialized.contains("raw-driver-secret"));
    assert!(serialized.contains("sha256:"));
    assert!(serialized.contains("tls_error"));
}

#[tokio::test]
async fn ambiguous_commit_records_unknown_transaction_outcome() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(AmbiguousWriteConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );
    let transaction = guard.begin().await.expect("begin");

    transaction.commit().await.expect_err("commit must be ambiguous");

    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("commit outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.transaction_outcome, AuditTransactionOutcome::Unknown);
}

#[tokio::test]
async fn agent_read_fails_when_outcome_cannot_be_recorded() {
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Outcome]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            allowed_agent_policy(),
            Arc::new(DenyApprovalSink),
            audit,
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .query("SELECT 1")
        .await
        .expect_err("agent audit failure must surface");

    assert!(
        error
            .to_string()
            .contains("audit recording failed after read execution")
    );
}

#[tokio::test]
async fn batch_records_correlated_redacted_intent_and_outcome() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );
    let statements = vec![("INSERT INTO jobs(secret) VALUES ('raw-secret')".into(), vec![])];

    guard.execute_in_transaction(&statements).await.expect("execute batch");

    let events = audit.events.lock().expect("event lock");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].operation_id, events[1].operation_id);
    assert_eq!(events[0].batch_id, events[1].batch_id);
    assert_eq!(events[0].redacted_sql, "[REDACTED]");
    assert!(!events[0].redacted_sql.contains("raw-secret"));
    assert_eq!(events[0].sql_hash.len(), 64);
}

#[tokio::test]
async fn local_unaudited_write_requires_explicit_opt_in() {
    let denied_executes = Arc::new(AtomicUsize::new(0));
    let denied = PolicyGuard::new(
        connection(denied_executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
        ),
    );
    denied
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("default local policy must require audit");
    assert_eq!(denied_executes.load(Ordering::SeqCst), 0);

    let allowed_executes = Arc::new(AtomicUsize::new(0));
    let mut policy = PolicyConfig::default();
    policy
        .environments
        .entry("local".into())
        .or_default()
        .human_allow_unaudited_writes = Some(true);
    let allowed = PolicyGuard::new(
        connection(allowed_executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(AutoApproveSink),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
        ),
    );
    let error = allowed
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("failed outcome must report uncertain execution");
    assert!(error.to_string().contains("operation may have succeeded"));
    assert_eq!(allowed_executes.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn null_sink_denies_production_write() {
    let executes = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(NullAuditSink),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("null sink must deny");

    assert_eq!(executes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn human_policy_deny_fails_closed_when_outcome_cannot_be_recorded() {
    let executes = Arc::new(AtomicUsize::new(0));
    let mut ctx = context(
        Principal::human_gui(),
        Environment::Local,
        PolicyConfig::default(),
        Arc::new(AutoApproveSink),
        Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Outcome])),
        Arc::new(AuditState::new()),
    );
    ctx.read_only = true;
    let guard = PolicyGuard::new(connection(executes.clone(), Arc::new(AtomicUsize::new(0))), ctx);

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("unaudited deny must fail closed");

    assert!(error.to_string().contains("audit recording failed"));
    assert_eq!(executes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn human_approval_deny_fails_closed_when_outcome_cannot_be_recorded() {
    let executes = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(DenyApprovalSink),
            Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Outcome])),
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("unaudited approval deny must fail closed");

    assert!(error.to_string().contains("audit recording failed"));
    assert_eq!(executes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn human_policy_deny_keeps_the_policy_message_when_audit_succeeds() {
    let executes = Arc::new(AtomicUsize::new(0));
    let mut ctx = context(
        Principal::human_gui(),
        Environment::Local,
        PolicyConfig::default(),
        Arc::new(AutoApproveSink),
        Arc::new(SequenceAuditSink::new(vec![])),
        Arc::new(AuditState::new()),
    );
    ctx.read_only = true;
    let guard = PolicyGuard::new(connection(executes.clone(), Arc::new(AtomicUsize::new(0))), ctx);

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("read-only write must be denied");

    assert!(error.to_string().contains("read-only"));
    assert!(!error.to_string().contains("audit recording failed"));
    assert_eq!(executes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_panicking_driver_write_records_an_unknown_terminal_outcome() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(PanickingConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("a panicking driver must surface as an error");
    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(!format!("{error}").contains("codec read past the end"));

    assert!(state.governed_writes_disabled());
    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
}

#[tokio::test]
async fn a_panicking_driver_read_records_a_failed_terminal_outcome() {
    let state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        Arc::new(PanickingConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            state.clone(),
        ),
    );

    let error = guard
        .list_tables()
        .await
        .expect_err("a panicking driver must surface as an error");
    assert!(matches!(error, DriverError::Internal(_)));

    let events = audit.events.lock().expect("event lock");
    let outcome = events.last().expect("outcome event");
    assert_ne!(outcome.terminal_status, AuditTerminalStatus::Succeeded);
}

struct CountingFaultSink {
    reports: Arc<AtomicUsize>,
}

impl crate::ConnectionFaultSink for CountingFaultSink {
    fn connection_became_unusable(&self, _operation: &str) {
        self.reports.fetch_add(1, Ordering::SeqCst);
    }
}

fn panicking_guard(reports: Arc<AtomicUsize>) -> PolicyGuard {
    PolicyGuard::new(
        Arc::new(PanickingConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    )
    .with_fault_sink(Arc::new(CountingFaultSink { reports }))
}

#[tokio::test]
async fn a_panicking_read_reports_the_connection_as_unusable() {
    let reports = Arc::new(AtomicUsize::new(0));
    let guard = panicking_guard(reports.clone());

    let error = guard.list_tables().await.expect_err("the panic must surface");

    assert!(matches!(error, DriverError::Internal(_)));
    assert_eq!(reports.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_panicking_write_reports_the_connection_as_unusable() {
    let reports = Arc::new(AtomicUsize::new(0));
    let guard = panicking_guard(reports.clone());

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("the panic must surface");

    assert_eq!(reports.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_operation_that_does_not_panic_reports_no_fault() {
    let reports = Arc::new(AtomicUsize::new(0));
    let guard = panicking_guard(reports.clone());

    guard.ping().await.expect("ping does not panic");

    assert_eq!(reports.load(Ordering::SeqCst), 0);
}

fn disconnected_guard(reports: Arc<AtomicUsize>) -> PolicyGuard {
    PolicyGuard::new(
        Arc::new(DisconnectedConn),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    )
    .with_fault_sink(Arc::new(CountingFaultSink { reports }))
}

#[tokio::test]
async fn a_disconnected_read_reports_the_connection_as_unusable_without_a_panic() {
    let reports = Arc::new(AtomicUsize::new(0));
    let guard = disconnected_guard(reports.clone());

    let error = guard
        .list_tables()
        .await
        .expect_err("the driver reported it is disconnected");

    assert!(matches!(error, DriverError::Disconnected));
    assert_eq!(
        reports.load(Ordering::SeqCst),
        1,
        "a Disconnected result must reach the fault sink immediately, not just a caught panic"
    );
}

#[tokio::test]
async fn a_disconnected_write_reports_the_connection_as_unusable_without_a_panic() {
    let reports = Arc::new(AtomicUsize::new(0));
    let guard = disconnected_guard(reports.clone());

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("the driver reported it is disconnected");

    assert_eq!(reports.load(Ordering::SeqCst), 1);
}

#[derive(Clone, Default)]
struct CapturedLogs(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for CapturedLogs {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.0.lock().expect("log lock").extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'writer> tracing_subscriber::fmt::MakeWriter<'writer> for CapturedLogs {
    type Writer = CapturedLogs;

    fn make_writer(&'writer self) -> Self::Writer {
        self.clone()
    }
}

#[test]
fn a_driver_panic_message_never_reaches_the_logs_or_the_error() {
    const CHILD_ENV: &str = "TABLEPRO_PANIC_AUDIT_TEST_CHILD";
    const TEST_NAME: &str = "guard::guard_tests::audit::a_driver_panic_message_never_reaches_the_logs_or_the_error";

    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().expect("test binary path"))
            .arg("--exact")
            .arg(TEST_NAME)
            .env(CHILD_ENV, "1")
            .output()
            .expect("run isolated tracing capture test");
        assert!(
            output.status.success(),
            "isolated tracing capture failed:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let logs = CapturedLogs::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(logs.clone())
        .with_ansi(false)
        .with_max_level(tracing::Level::TRACE)
        .finish();
    let guard = PolicyGuard::new(
        Arc::new(PanickingConn),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );

    tracing::subscriber::set_global_default(subscriber).expect("install process subscriber");
    let error = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("test runtime")
        .block_on(guard.list_tables())
        .expect_err("a panicking driver must surface as an error");

    let logged = String::from_utf8(logs.0.lock().expect("log lock").clone()).expect("utf-8 logs");
    assert!(
        logged.contains("driver panicked"),
        "the panic is still reported: {logged}"
    );
    assert!(
        logged.contains("operation=\"LIST TABLES\""),
        "the captured event belongs to this guarded operation: {logged}"
    );
    assert!(
        !logged.contains("codec read past the end of the buffer"),
        "the panic message must not be logged: {logged}"
    );
    assert!(!error.to_string().contains("codec read past the end of the buffer"));
}
