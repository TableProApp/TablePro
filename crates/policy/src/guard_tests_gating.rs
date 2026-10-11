use sha2::Digest;

use super::*;

#[tokio::test]
async fn categorical_agent_denial_skips_blast_radius_query() {
    let queries = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("UPDATE jobs SET status = 'done' WHERE id = 1")
        .await
        .expect_err("agent write must be denied");

    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn read_only_denial_skips_blast_radius_query() {
    let queries = Arc::new(AtomicUsize::new(0));
    let mut guard_context = context(
        Principal::human_gui(),
        Environment::Prod,
        PolicyConfig::default(),
        Arc::new(AutoApproveSink),
        Arc::new(SequenceAuditSink::new(vec![])),
        Arc::new(AuditState::new()),
    );
    guard_context.read_only = true;
    let guard = PolicyGuard::new(query_counting_connection(queries.clone()), guard_context);

    guard
        .execute("UPDATE jobs SET status = 'done' WHERE id = 1")
        .await
        .expect_err("read-only write must be denied");

    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn dangerous_effects_ask_for_approval_without_running_a_blast_radius_query() {
    let queries = Arc::new(AtomicUsize::new(0));
    let approvals = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("COPY items TO PROGRAM 'echo unsafe'")
        .await
        .expect("the mocked approval sink approves the administrative statement");

    assert_eq!(approvals.load(Ordering::SeqCst), 1);
    assert_eq!(queries.load(Ordering::SeqCst), 0);
    let events = audit.events.lock().expect("audit events");
    assert!(events.iter().any(|event| {
        event
            .decision_rule
            .trim_end_matches(":approved")
            .split('+')
            .any(|rule| rule == "human_dangerous_effect_approval")
    }));
}

#[tokio::test]
async fn write_approval_overrides_the_human_unparseable_allow_rule() {
    let approvals = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let mut policy = PolicyConfig::default();
    let local = policy.environments.entry("local".into()).or_default();
    local.human_approve_writes = Some(true);
    local.human_approve_unparseable = Some(false);
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("DELETE FROM items WHERE id = 1; SELECT (")
        .await
        .expect("the mocked approval sink approves the malformed script");

    assert_eq!(approvals.load(Ordering::SeqCst), 1);
    let events = audit.events.lock().expect("audit events");
    assert!(events.iter().any(|event| {
        event
            .decision_rule
            .trim_end_matches(":approved")
            .split('+')
            .any(|rule| rule == "human_write_approve")
    }));
}

#[tokio::test]
async fn unknown_effects_require_approval_when_unparseable_human_sql_is_allowed() {
    let approvals = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let mut policy = PolicyConfig::default();
    let local = policy.environments.entry("local".into()).or_default();
    local.human_approve_writes = Some(false);
    local.human_approve_unparseable = Some(false);
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("DELETE FROM items WHERE id = 1; SELECT (")
        .await
        .expect("the mocked approval sink approves the malformed script");

    assert_eq!(approvals.load(Ordering::SeqCst), 1);
    let events = audit.events.lock().expect("audit events");
    assert!(events.iter().any(|event| {
        event
            .decision_rule
            .trim_end_matches(":approved")
            .split('+')
            .any(|rule| rule == "human_dangerous_effect_approval")
    }));
}

#[tokio::test]
async fn implicit_transaction_mode_is_denied_before_dispatch_and_audited() {
    let executes = Arc::new(AtomicUsize::new(0));
    let approvals = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let mut guard_context = context(
        Principal::human_gui(),
        Environment::Prod,
        PolicyConfig::default(),
        Arc::new(CountingApprovalSink {
            calls: approvals.clone(),
        }),
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    guard_context.driver_id = "mysql".into();
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        guard_context,
    );

    guard
        .execute("SET autocommit = 0")
        .await
        .expect_err("shared connection must refuse implicit transaction mode");

    assert_eq!(executes.load(Ordering::SeqCst), 0);
    assert_eq!(approvals.load(Ordering::SeqCst), 0);
    let events = audit.events.lock().expect("audit events");
    let event = events.last().expect("denial outcome");
    assert_eq!(event.decision_rule, "transaction_control_needs_session");
    assert_eq!(event.terminal_status, AuditTerminalStatus::Denied);
}

#[tokio::test]
async fn disabled_audit_state_cannot_be_bypassed_by_approval() {
    let queries = Arc::new(AtomicUsize::new(0));
    let approvals = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::with_governed_writes_disabled()),
        ),
    );

    guard
        .execute("UPDATE jobs SET status = 'done' WHERE id = 1")
        .await
        .expect_err("disabled audit state must deny the write");

    assert_eq!(approvals.load(Ordering::SeqCst), 0);
    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn agent_transaction_read_intent_failure_prevents_driver_query() {
    let queries = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            allowed_agent_policy(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Intent])),
            Arc::new(AuditState::new()),
        ),
    );
    let mut transaction = guard.begin().await.expect("begin");

    transaction
        .query("SELECT 1")
        .await
        .expect_err("read intent failure must surface");

    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn required_intent_failure_prevents_driver_execution() {
    let executes = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Intent]));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit,
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("intent must fail");

    assert!(
        matches!(&error, DriverError::PolicyDenied(message) if message.contains("audit intent could not be persisted"))
    );
    assert_eq!(executes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn commit_intent_failure_prevents_inner_commit() {
    let commits = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Intent]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), commits.clone()),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit,
            Arc::new(AuditState::new()),
        ),
    );
    let transaction = guard.begin().await.expect("begin");

    let error = transaction.commit().await.expect_err("commit intent must fail");

    assert!(
        matches!(&error, DriverError::PolicyDenied(message) if message.contains("audit intent could not be persisted"))
    );
    assert_eq!(commits.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn rollback_uses_distinct_operation_class() {
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
    let transaction = guard.begin().await.expect("begin");

    transaction.rollback().await.expect("rollback");

    let events = audit.events.lock().expect("event lock");
    assert_eq!(events.len(), 2);
    assert!(
        events
            .iter()
            .all(|event| event.operation_class == AuditOperationClass::TransactionRollback)
    );
    assert_eq!(events[0].phase, AuditRecordPhase::Intent);
    assert_eq!(events[1].transaction_outcome, AuditTransactionOutcome::RolledBack);
}

#[tokio::test]
async fn approve_once_authorizes_only_the_current_operation() {
    let executes = Arc::new(AtomicUsize::new(0));
    let approvals = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(SequenceApprovalSink {
                calls: approvals.clone(),
                outcomes: Mutex::new(vec![ApprovalOutcome::AllowOnce, ApprovalOutcome::Deny]),
            }),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect("first operation should be approved");
    guard
        .execute("INSERT INTO jobs(id) VALUES (2)")
        .await
        .expect_err("second operation must request approval again");

    assert_eq!(approvals.load(Ordering::SeqCst), 2);
    assert_eq!(executes.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn transaction_batch_requests_one_approval() {
    let executes = Arc::new(AtomicUsize::new(0));
    let approvals = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(CountingApprovalSink {
                calls: approvals.clone(),
            }),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );
    let statements = vec![
        ("INSERT INTO jobs(id) VALUES (1)".into(), vec![]),
        ("INSERT INTO jobs(id) VALUES (2)".into(), vec![]),
    ];

    let rows = guard.execute_in_transaction(&statements).await.expect("approved batch");

    assert_eq!(rows, vec![1, 1]);
    assert_eq!(approvals.load(Ordering::SeqCst), 1);
    assert_eq!(executes.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn blast_radius_count_runs_through_the_controlled_query_path() {
    let queries = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );

    guard
        .execute("UPDATE jobs SET status = 'done' WHERE id = 1")
        .await
        .expect("local write");

    assert_eq!(queries.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_side_effecting_predicate_is_never_run_by_the_blast_radius_count() {
    for sql in [
        "DELETE FROM jobs WHERE pg_terminate_backend(pid)",
        "UPDATE jobs SET status = 'done' WHERE nextval('job_seq') > 0",
    ] {
        let queries = Arc::new(AtomicUsize::new(0));
        let audit = Arc::new(SequenceAuditSink::new(vec![]));
        let guard = PolicyGuard::new(
            query_counting_connection(queries.clone()),
            context(
                Principal::human_gui(),
                Environment::Local,
                PolicyConfig::default(),
                Arc::new(AutoApproveSink),
                audit.clone(),
                Arc::new(AuditState::new()),
            ),
        );

        guard.execute(sql).await.expect("approved write");

        assert_eq!(queries.load(Ordering::SeqCst), 0, "{sql}");
        let events = audit.events.lock().expect("audit events");
        let Some(event) = events
            .iter()
            .find(|event| event.decision_rule.contains("human_dangerous_effect_approval"))
        else {
            panic!("the dangerous effect must remain in the approval decision: {events:?}");
        };
        assert!(
            event.decision_rule.contains("blast_radius_unknown"),
            "the joined verdict must retain the missing estimate reason: {event:?}"
        );
    }
}

#[tokio::test]
async fn an_expired_deadline_skips_the_blast_radius_count() {
    let queries = Arc::new(AtomicUsize::new(0));
    let guard = PolicyGuard::new(
        query_counting_connection(queries.clone()),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    );
    let control = OperationControl::with_timeout(std::time::Duration::ZERO);

    let error = guard
        .execute_controlled("UPDATE jobs SET status = 'done' WHERE id = 1", &control)
        .await
        .expect_err("expired control must refuse the write");

    assert!(
        matches!(error, DriverError::TimedOut) || error.to_string().contains("timed out"),
        "{error}"
    );
    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn list_views_records_a_governed_read_outcome() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    let views = guard.list_views().await.expect("list views");
    assert!(views.is_empty());

    let events = audit.events.lock().expect("event lock");
    let expected_hash = hex::encode(sha2::Sha256::digest(b"LIST VIEWS"));
    assert!(
        events
            .iter()
            .any(|event| event.decision_rule == "metadata_read" && event.sql_hash == expected_hash),
        "list_views must write a metadata audit record"
    );
}

#[tokio::test]
async fn list_databases_is_a_governed_read_with_its_own_audit_record() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .list_databases()
        .await
        .expect_err("the stub driver lists no databases");
    assert!(matches!(error, DriverError::Unsupported(_)), "{error}");

    let events = audit.events.lock().expect("event lock");
    let expected_hash = hex::encode(sha2::Sha256::digest(b"LIST DATABASES"));
    assert!(
        events
            .iter()
            .any(|event| event.decision_rule == "metadata_read" && event.sql_hash == expected_hash),
        "list_databases must write a metadata audit record"
    );
}

#[tokio::test]
async fn list_objects_reports_an_unsupported_kind_and_audits_the_read_with_its_target() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .list_objects(tablepro_core::CatalogObjectKind::Routine, Some("public"))
        .await
        .expect_err("the mock driver declares no catalog kinds");
    assert!(matches!(error, DriverError::Unsupported(_)), "{error:?}");

    let events = audit.events.lock().expect("event lock");
    let expected_hash = hex::encode(sha2::Sha256::digest(b"LIST OBJECTS"));
    assert!(
        events.iter().any(|event| event.decision_rule == "metadata_read"
            && event.sql_hash == expected_hash
            && event.targets == vec!["routine:public".to_string()]),
        "list_objects must write a metadata audit record naming kind and schema"
    );
}

#[tokio::test]
async fn list_objects_is_denied_when_the_agent_read_intent_cannot_be_recorded() {
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
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Intent])),
            Arc::new(AuditState::new()),
        ),
    );

    let error = guard
        .list_objects(tablepro_core::CatalogObjectKind::Role, None)
        .await
        .expect_err("a failed read intent must deny the listing");

    assert!(!matches!(error, DriverError::Unsupported(_)), "{error:?}");
}

#[tokio::test]
async fn list_objects_audit_target_leaves_out_the_schema_for_unscoped_kinds() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = PolicyGuard::new(
        connection(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );

    let _ = guard
        .list_objects(tablepro_core::CatalogObjectKind::Role, Some("public"))
        .await;

    let events = audit.events.lock().expect("event lock");
    assert!(events.iter().any(|event| event.targets == vec!["role".to_string()]));
}
